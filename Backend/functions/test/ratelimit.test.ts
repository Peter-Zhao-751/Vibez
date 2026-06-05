import {describe, it, expect} from "vitest";
import {
  ID_BUCKET,
  IP_BUCKET,
  GLOBAL_BUCKET,
  ESCALATION_WINDOW_MS,
  BucketState,
  LimiterEntry,
  refill,
  tryTake,
  decideLocally,
  recordGlobalDeny,
  BoundedMap,
} from "../src/ratelimit";

const T0 = 1_700_000_000_000;

describe("bucket configs", () => {
  it("match the spec: id 5/1s, ip 20/5s, global 200/100s", () => {
    expect(ID_BUCKET).toEqual({capacity: 5, refillPerSec: 1});
    expect(IP_BUCKET).toEqual({capacity: 20, refillPerSec: 5});
    expect(GLOBAL_BUCKET).toEqual({capacity: 200, refillPerSec: 100});
  });
});

describe("refill", () => {
  it("grows tokens by elapsed time, capped at capacity", () => {
    const s = {tokens: 0, lastRefillMs: T0};
    expect(refill(s, T0 + 2500, ID_BUCKET).tokens).toBeCloseTo(2.5);
    expect(refill(s, T0 + 60_000, ID_BUCKET).tokens).toBe(5);
  });
  it("never goes backwards on clock skew", () => {
    const s = {tokens: 3, lastRefillMs: T0};
    expect(refill(s, T0 - 5000, ID_BUCKET).tokens).toBe(3);
  });
});

describe("tryTake", () => {
  it("treats absent state as a full bucket (first sight)", () => {
    const r = tryTake(undefined, T0, ID_BUCKET);
    expect(r.allowed).toBe(true);
    expect(r.next.tokens).toBe(4);
  });
  it("drains the burst then denies with retryAfterMs <= 1s", () => {
    let s;
    for (let i = 0; i < 5; i++) {
      const r = tryTake(s, T0, ID_BUCKET);
      expect(r.allowed).toBe(true);
      s = r.next;
    }
    const denied = tryTake(s, T0, ID_BUCKET);
    expect(denied.allowed).toBe(false);
    expect(denied.retryAfterMs).toBeGreaterThan(0);
    expect(denied.retryAfterMs).toBeLessThanOrEqual(1000);
  });
  it("allows again after one refill interval", () => {
    let s;
    for (let i = 0; i < 5; i++) s = tryTake(s, T0, ID_BUCKET).next;
    const r = tryTake(s, T0 + 1000, ID_BUCKET);
    expect(r.allowed).toBe(true);
  });
  it("honors non-ID configs (IP and GLOBAL refill rates)", () => {
    // IP bucket refills 5/sec: drain 1, wait 200ms, token is back.
    let ip = tryTake(undefined, T0, IP_BUCKET).next;
    for (let i = 0; i < 19; i++) ip = tryTake(ip, T0, IP_BUCKET).next;
    expect(tryTake(ip, T0, IP_BUCKET).allowed).toBe(false);
    expect(tryTake(ip, T0 + 200, IP_BUCKET).allowed).toBe(true);
    // GLOBAL refills 100/sec: after a full drain, 10ms restores a token.
    let g;
    for (let i = 0; i < 200; i++) g = tryTake(g, T0, GLOBAL_BUCKET).next;
    expect(tryTake(g, T0, GLOBAL_BUCKET).allowed).toBe(false);
    expect(tryTake(g, T0 + 10, GLOBAL_BUCKET).allowed).toBe(true);
  });
});

describe("decideLocally (lazy escalation)", () => {
  it("allows from the local bucket without escalation", () => {
    const d = decideLocally(undefined, T0, ID_BUCKET);
    expect(d.kind).toBe("allow");
  });
  it("escalates when the local bucket is dry", () => {
    let e;
    for (let i = 0; i < 5; i++) {
      const d = decideLocally(e, T0, ID_BUCKET);
      expect(d.kind).toBe("allow");
      e = d.next;
    }
    const d = decideLocally(e, T0, ID_BUCKET);
    expect(d.kind).toBe("escalate");
    expect(d.next.escalatedUntilMs).toBe(T0 + ESCALATION_WINDOW_MS);
  });
  it("keeps escalating inside the window even with local tokens", () => {
    let e;
    for (let i = 0; i < 6; i++) e = decideLocally(e, T0, ID_BUCKET).next;
    // 30s later the local bucket has refilled, but the window is open.
    const d = decideLocally(e, T0 + 30_000, ID_BUCKET);
    expect(d.kind).toBe("escalate");
  });
  it("returns to the local fast path after the window closes", () => {
    let e;
    for (let i = 0; i < 6; i++) e = decideLocally(e, T0, ID_BUCKET).next;
    const d = decideLocally(e, T0 + ESCALATION_WINDOW_MS + 5000, ID_BUCKET);
    expect(d.kind).toBe("allow");
  });
  it("denies from the negative cache without I/O", () => {
    let e;
    for (let i = 0; i < 6; i++) e = decideLocally(e, T0, ID_BUCKET).next;
    e = recordGlobalDeny(e, T0, 800);
    const d = decideLocally(e, T0 + 100, ID_BUCKET);
    expect(d.kind).toBe("deny");
    if (d.kind === "deny") expect(d.retryAfterMs).toBe(700);
    const after = decideLocally(e, T0 + 900, ID_BUCKET);
    expect(after.kind).not.toBe("deny");
  });
});

describe("BoundedMap", () => {
  it("evicts the oldest key at capacity", () => {
    const m = new BoundedMap<number>(2);
    m.set("a", 1);
    m.set("b", 2);
    m.set("c", 3);
    expect(m.get("a")).toBeUndefined();
    expect(m.get("b")).toBe(2);
    expect(m.get("c")).toBe(3);
  });
  it("re-setting an existing key refreshes it instead of evicting", () => {
    const m = new BoundedMap<number>(2);
    m.set("a", 1);
    m.set("b", 2);
    m.set("a", 9);
    m.set("c", 3);
    expect(m.get("a")).toBe(9);
    expect(m.get("b")).toBeUndefined();
  });
});

describe("caller-loop integration (decideLocally + shared global bucket)", () => {
  it("escalates to the shared bucket and negative-caches its deny", () => {
    // Two "instances", one shared (Firestore-like) bucket state.
    let shared: BucketState | undefined;
    let a: LimiterEntry | undefined;
    let denied = 0;
    let allowed = 0;
    // Instance A: 12 rapid requests at T0. Locally: 5 allow, then
    // escalate each time; shared bucket allows 5 more, then denies.
    for (let i = 0; i < 12; i++) {
      const d = decideLocally(a, T0, ID_BUCKET);
      a = d.next;
      if (d.kind === "allow") {
        allowed++;
      } else if (d.kind === "deny") {
        denied++;
      } else {
        const take = tryTake(shared, T0, ID_BUCKET);
        if (take.allowed) shared = take.next;
        if (take.allowed) {
          allowed++;
        } else {
          denied++;
          a = recordGlobalDeny(a, T0, take.retryAfterMs);
        }
      }
    }
    expect(allowed).toBe(10); // 5 local + 5 shared
    expect(denied).toBe(2);   // 11th escalates+denies, 12th negative-caches
  });
});
