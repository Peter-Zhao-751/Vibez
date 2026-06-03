import {describe, it, expect} from "vitest";
import {
  clampDuration,
  delayForEvent,
  shouldScheduleUnblock,
  buildApnsPayload,
  APNS_HEADERS,
  UNBLOCK_BUFFER_SECONDS,
} from "../src/scheduling";

describe("clampDuration", () => {
  it("passes valid values through, rounded", () => {
    expect(clampDuration(30, 999)).toBe(30);
    expect(clampDuration(900.4, 999)).toBe(900);
  });
  it("clamps out-of-range to [1, 86400]", () => {
    expect(clampDuration(0, 999)).toBe(1);
    expect(clampDuration(99999999, 999)).toBe(86400);
  });
  it("falls back on non-numbers", () => {
    expect(clampDuration("x", 30)).toBe(30);
    expect(clampDuration(undefined, 900)).toBe(900);
    expect(clampDuration(NaN, 7)).toBe(7);
  });
  it("keeps the exact boundary values 1 and 86400", () => {
    expect(clampDuration(1, 999)).toBe(1);
    expect(clampDuration(86400, 999)).toBe(86400);
  });
  it("clamps negative input up to 1", () => {
    expect(clampDuration(-5, 999)).toBe(1);
  });
});

describe("delayForEvent", () => {
  const d = {done: 30, needsInput: 900};
  it("uses the done duration for done", () => {
    expect(delayForEvent("done", d)).toBe(30 + UNBLOCK_BUFFER_SECONDS);
  });
  it("uses needsInput for needs-input and absent", () => {
    expect(delayForEvent("needs-input", d))
      .toBe(900 + UNBLOCK_BUFFER_SECONDS);
    expect(delayForEvent(undefined, d))
      .toBe(900 + UNBLOCK_BUFFER_SECONDS);
  });
});

describe("shouldScheduleUnblock", () => {
  it("schedules a timed block that has a session", () => {
    expect(shouldScheduleUnblock(
      {shield: "on", session: "s1", event: "done"})).toBe(true);
    expect(shouldScheduleUnblock(
      {session: "s1", event: "needs-input"})).toBe(true);
    expect(shouldScheduleUnblock({session: "s1"})).toBe(true);
  });
  it("skips replies, focus/untagged, and replied", () => {
    expect(shouldScheduleUnblock(
      {shield: "off", session: "s1"})).toBe(false);
    expect(shouldScheduleUnblock({event: "done"})).toBe(false);
    expect(shouldScheduleUnblock({session: "nosid"})).toBe(false);
    expect(shouldScheduleUnblock(
      {session: "s1", event: "replied"})).toBe(false);
  });
});

describe("buildApnsPayload", () => {
  it("puts custom fields + reason at the top level", () => {
    const p = buildApnsPayload({
      title: "T", body: "B", event: "done", shield: "off",
      session: "s1", agent: "cc", reason: "timeout",
    });
    expect(p.session).toBe("s1");
    expect(p.reason).toBe("timeout");
    expect(p.shield).toBe("off");
  });
  it("uses passive interruption + no sound for shield:off", () => {
    const p = buildApnsPayload({title: "T", body: "B", shield: "off"});
    expect(p.aps["interruption-level"]).toBe("passive");
    expect(p.aps.sound).toBeUndefined();
  });
  it("uses sound for non-off pushes", () => {
    const p = buildApnsPayload({title: "T", body: "B", shield: "on"});
    expect(p.aps.sound).toBe("default");
  });
  it("omits unset optional fields and mirrors title/body at top level", () => {
    const p = buildApnsPayload({title: "T", body: "B"});
    expect(p.title).toBe("T");
    expect(p.body).toBe("B");
    expect(p.aps.alert).toEqual({title: "T", body: "B"});
    expect(p.event).toBeUndefined();
    expect(p.reason).toBeUndefined();
  });
});

describe("APNS_HEADERS", () => {
  it("declares an alert push at priority 10", () => {
    expect(APNS_HEADERS["apns-push-type"]).toBe("alert");
    expect(APNS_HEADERS["apns-priority"]).toBe("10");
  });
});
