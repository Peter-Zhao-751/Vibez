import {describe, it, expect} from "vitest";
import {
  VIBEZ_ID_PATTERN,
  MAX_TITLE_CHARS,
  MAX_BODY_CHARS,
  MAX_CONTENT_LENGTH_BYTES,
  MIN_FCM_TOKEN_LENGTH,
  MAX_FCM_TOKEN_LENGTH,
  MAX_DEVICES_PER_VIBEZ_ID,
  clampText,
  normalizePlatform,
  validateNotifyBody,
} from "../src/validation";

const VALID = {
  vibezId: "moss-pine-fox-jazz",
  title: "Fix login bug",
  body: "Should I commit this?",
};

describe("constants", () => {
  it("match the spec", () => {
    expect(MAX_TITLE_CHARS).toBe(100);
    expect(MAX_BODY_CHARS).toBe(200);
    expect(MAX_CONTENT_LENGTH_BYTES).toBe(8192);
    expect(MIN_FCM_TOKEN_LENGTH).toBe(20);
    expect(MAX_FCM_TOKEN_LENGTH).toBe(512);
    expect(MAX_DEVICES_PER_VIBEZ_ID).toBe(10);
  });
});

describe("VIBEZ_ID_PATTERN", () => {
  it("accepts 4 hyphenated 3-5 letter words", () => {
    expect(VIBEZ_ID_PATTERN.test("moss-pine-fox-jazz")).toBe(true);
  });
  it("rejects wrong shapes", () => {
    expect(VIBEZ_ID_PATTERN.test("moss-pine-fox")).toBe(false);
    expect(VIBEZ_ID_PATTERN.test("Moss-pine-fox-jazz")).toBe(false);
    expect(VIBEZ_ID_PATTERN.test("toolong-pine-fox-jazz")).toBe(false);
  });
});

describe("clampText", () => {
  it("passes short text through untouched", () => {
    expect(clampText("hello", 100)).toBe("hello");
  });
  it("truncates at max chars with a trailing ellipsis", () => {
    const long = "x".repeat(150);
    const out = clampText(long, 100);
    expect(out.length).toBe(100);
    expect(out.endsWith("…")).toBe(true);
  });
  it("keeps text exactly at max untouched", () => {
    const exact = "x".repeat(100);
    expect(clampText(exact, 100)).toBe(exact);
  });
  it("never splits a surrogate pair at the clamp boundary", () => {
    // 98 x's + 😀 (2 code units) + 'y' = 101 units; a naive cut at 99
    // would split the emoji.
    const input = "x".repeat(98) + "😀" + "y";
    const out = clampText(input, 100);
    expect(out.length).toBeLessThanOrEqual(100);
    const beforeEllipsis = out.charCodeAt(out.length - 2);
    expect(beforeEllipsis < 0xD800 || beforeEllipsis > 0xDBFF).toBe(true);
  });
});

describe("normalizePlatform", () => {
  it("passes known platforms through", () => {
    expect(normalizePlatform("ios")).toBe("ios");
    expect(normalizePlatform("web")).toBe("web");
  });
  it("coerces everything else to unknown", () => {
    expect(normalizePlatform("android")).toBe("unknown");
    expect(normalizePlatform(42)).toBe("unknown");
    expect(normalizePlatform(undefined)).toBe("unknown");
    expect(normalizePlatform("x".repeat(5000))).toBe("unknown");
  });
});

describe("validateNotifyBody", () => {
  it("accepts a minimal valid body", () => {
    const r = validateNotifyBody(VALID);
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.fields.vibezId).toBe(VALID.vibezId);
      expect(r.fields.event).toBeUndefined();
    }
  });
  it("accepts all optional fields with valid values", () => {
    const r = validateNotifyBody({
      ...VALID,
      event: "needs-input",
      shield: "on",
      session: "abc-123_DEF.x:9",
      agent: "cc",
    });
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.fields.session).toBe("abc-123_DEF.x:9");
  });
  it("accepts every known agent tag", () => {
    for (const agent of ["cc", "cx", "cu"]) {
      expect(validateNotifyBody({...VALID, agent}).ok).toBe(true);
    }
  });
  it("rejects bad vibezId / missing title / missing body", () => {
    expect(validateNotifyBody({...VALID, vibezId: "nope"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, title: ""}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, body: ""}).ok).toBe(false);
    expect(validateNotifyBody(null).ok).toBe(false);
    expect(validateNotifyBody("string").ok).toBe(false);
  });
  it("rejects unknown enum values (400, not clamp)", () => {
    expect(validateNotifyBody({...VALID, event: "explode"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, shield: "maybe"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, agent: "gpt"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, event: 7}).ok).toBe(false);
  });
  it("rejects bad sessions: too long, bad chars, empty", () => {
    expect(validateNotifyBody(
      {...VALID, session: "x".repeat(129)}).ok).toBe(false);
    expect(validateNotifyBody(
      {...VALID, session: "has space"}).ok).toBe(false);
    expect(validateNotifyBody({...VALID, session: ""}).ok).toBe(false);
  });
  it("clamps oversized title/body instead of rejecting", () => {
    const r = validateNotifyBody({
      ...VALID,
      title: "t".repeat(300),
      body: "b".repeat(900),
    });
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.fields.title.length).toBe(MAX_TITLE_CHARS);
      expect(r.fields.body.length).toBe(MAX_BODY_CHARS);
      expect(r.fields.body.endsWith("…")).toBe(true);
    }
  });
  it("accepts session at exactly the 128-char limit", () => {
    const r = validateNotifyBody({...VALID, session: "x".repeat(128)});
    expect(r.ok).toBe(true);
  });
  it("drops unknown fields by construction", () => {
    const r = validateNotifyBody({...VALID, reason: "timeout", evil: "x"});
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect("reason" in r.fields).toBe(false);
      expect("evil" in r.fields).toBe(false);
    }
  });
});
