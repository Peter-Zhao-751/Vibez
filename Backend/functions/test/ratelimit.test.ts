import {describe, it, expect} from "vitest";
import {
  ID_BUCKET,
  IP_BUCKET,
  GLOBAL_BUCKET,
  ESCALATION_WINDOW_MS,
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
