import { describe, expect, it } from "vitest";
import { parseCommand } from "../src/schema";

describe("parseCommand", () => {
  it("accepts a full valid command", () => {
    const c = parseCommand({
      id: "11111111-1111-1111-1111-111111111111",
      action: "on",
      brightness: 30,
      color_temp_k: 2700,
      created_at: "2026-05-31T10:00:00Z",
      source_msg_id: "manual",
    });
    expect(c?.action).toBe("on");
    expect(c?.color_temp_k).toBe(2700);
  });

  it("accepts a minimal off command", () => {
    const c = parseCommand({
      id: "a",
      action: "off",
      created_at: "2026-05-31T10:00:00Z",
      source_msg_id: "m",
    });
    expect(c?.action).toBe("off");
    expect(c?.brightness).toBeUndefined();
  });

  it("returns null for an unknown action", () => {
    expect(
      parseCommand({ id: "a", action: "dim", created_at: "x", source_msg_id: "m" })
    ).toBeNull();
  });

  it("returns null when a required field is missing", () => {
    expect(parseCommand({ action: "on" })).toBeNull();
  });

  it("returns null for out-of-range brightness", () => {
    expect(
      parseCommand({ id: "a", action: "on", brightness: 150, created_at: "x", source_msg_id: "m" })
    ).toBeNull();
  });

  it("returns null for non-object input", () => {
    expect(parseCommand("nope")).toBeNull();
    expect(parseCommand(null)).toBeNull();
  });

  it("returns null when extra/unknown properties are present", () => {
    expect(
      parseCommand({
        id: "a",
        action: "on",
        created_at: "2026-05-31T10:00:00Z",
        source_msg_id: "m",
        injected: "x",
      })
    ).toBeNull();
  });
});
