import { describe, expect, it } from "vitest";
import { parseLlmToolUse } from "../src/llm";

describe("parseLlmToolUse", () => {
  it("passes through a valid on command", () => {
    expect(parseLlmToolUse({ action: "on", brightness: 30, color_temp_k: 2700 }))
      .toEqual({ action: "on", brightness: 30, color_temp_k: 2700 });
  });

  it("clamps color_temp_k above range to 6500", () => {
    expect(parseLlmToolUse({ action: "on", color_temp_k: 9000 }))
      .toEqual({ action: "on", color_temp_k: 6500 });
  });

  it("clamps brightness below range to 0 and rounds floats", () => {
    expect(parseLlmToolUse({ action: "set", brightness: -10 }))
      .toEqual({ action: "set", brightness: 0 });
    expect(parseLlmToolUse({ action: "set", brightness: 20.6 }))
      .toEqual({ action: "set", brightness: 21 });
  });

  it("strips brightness/color from off", () => {
    expect(parseLlmToolUse({ action: "off", brightness: 50 }))
      .toEqual({ action: "off" });
  });

  it("returns null for an unknown action", () => {
    expect(parseLlmToolUse({ action: "dim" })).toBeNull();
  });

  it("returns null for non-object input", () => {
    expect(parseLlmToolUse(null)).toBeNull();
    expect(parseLlmToolUse("on")).toBeNull();
  });
});
