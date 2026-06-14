import { describe, expect, it } from "vitest";
import { formatQueuedReply, formatUnparseableReply } from "../src/reply";
import type { LlmCommand } from "../src/schema";

// ---------------------------------------------------------------------------
// formatUnparseableReply
// ---------------------------------------------------------------------------
describe("formatUnparseableReply", () => {
  it("produces two lines with request echoed and hint", () => {
    const result = formatUnparseableReply("turn the lamp on");
    const lines = result.split("\n");
    expect(lines).toHaveLength(2);
    expect(lines[0]).toBe('Got request — "turn the lamp on"');
    expect(lines[1]).toBe("Couldn't understand that command. Try e.g. 'on, warm, 30%'.");
  });

  it("collapses inner whitespace in the request", () => {
    const result = formatUnparseableReply("turn   on\nthe\tlamp");
    const lines = result.split("\n");
    expect(lines[0]).toBe('Got request — "turn on the lamp"');
  });

  it("trims leading and trailing whitespace before collapsing", () => {
    const result = formatUnparseableReply("  on  ");
    const lines = result.split("\n");
    expect(lines[0]).toBe('Got request — "on"');
  });

  it("truncates request to 200 chars and appends ellipsis", () => {
    const long = "a".repeat(210);
    const result = formatUnparseableReply(long);
    const lines = result.split("\n");
    // The quoted portion inside the first-line should be 200 chars + "…"
    expect(lines[0]).toBe(`Got request — "${"a".repeat(200)}…"`);
  });

  it("does NOT append ellipsis when request is exactly 200 chars", () => {
    const exact = "b".repeat(200);
    const result = formatUnparseableReply(exact);
    const lines = result.split("\n");
    expect(lines[0]).toBe(`Got request — "${"b".repeat(200)}"`);
    expect(lines[0]).not.toContain("…");
  });
});

// ---------------------------------------------------------------------------
// formatQueuedReply — off
// ---------------------------------------------------------------------------
describe("formatQueuedReply — off command", () => {
  it("produces three lines for an off command", () => {
    const cmd: LlmCommand = { action: "off" };
    const result = formatQueuedReply("lamp off", cmd);
    const lines = result.split("\n");
    expect(lines).toHaveLength(3);
    expect(lines[0]).toBe('Got request — "lamp off"');
    expect(lines[1]).toBe("Got response from the model — off");
    expect(lines[2]).toBe("Executing — turning the lamp off");
  });
});

// ---------------------------------------------------------------------------
// formatQueuedReply — on / set with various field combinations
// ---------------------------------------------------------------------------
describe("formatQueuedReply — on/set command", () => {
  it("bare 'on' with no optional fields", () => {
    const cmd: LlmCommand = { action: "on" };
    const result = formatQueuedReply("lamp on", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toBe("Got response from the model — on");
    expect(lines[2]).toBe("Executing — turning the lamp on");
  });

  it("set with brightness only (no color)", () => {
    const cmd: LlmCommand = { action: "set", brightness: 50 };
    const result = formatQueuedReply("set brightness 50", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toBe("Got response from the model — set, brightness 50");
    expect(lines[2]).toBe("Executing — turning the lamp on at 50%");
  });

  it("set with brightness and color — warm bucket (2700 K)", () => {
    const cmd: LlmCommand = { action: "set", brightness: 30, color_temp_k: 2700 };
    const result = formatQueuedReply("turn on, warm, 30%", cmd);
    const lines = result.split("\n");
    expect(lines[0]).toBe('Got request — "turn on, warm, 30%"');
    expect(lines[1]).toBe("Got response from the model — set, brightness 30, color 2700K (warm)");
    expect(lines[2]).toBe("Executing — turning the lamp on at 30%, warm (2700K)");
  });

  it("set with color only (no brightness)", () => {
    const cmd: LlmCommand = { action: "set", color_temp_k: 4000 };
    const result = formatQueuedReply("neutral light", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toBe("Got response from the model — set, color 4000K (neutral)");
    expect(lines[2]).toBe("Executing — turning the lamp on, neutral (4000K)");
  });

  it("on with brightness and color", () => {
    const cmd: LlmCommand = { action: "on", brightness: 80, color_temp_k: 5000 };
    const result = formatQueuedReply("on bright cool", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toBe("Got response from the model — on, brightness 80, color 5000K (cool)");
    expect(lines[2]).toBe("Executing — turning the lamp on at 80%, cool (5000K)");
  });

  it("set with brightness 0 — zero is treated as a valid brightness value", () => {
    const cmd: LlmCommand = { action: "set", brightness: 0 };
    const result = formatQueuedReply("dim to zero", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toBe("Got response from the model — set, brightness 0");
    expect(lines[2]).toBe("Executing — turning the lamp on at 0%");
  });
});

// ---------------------------------------------------------------------------
// Kelvin bucket boundary tests
// ---------------------------------------------------------------------------
describe("formatQueuedReply — kelvin word mapping", () => {
  it("3000 K → warm", () => {
    const cmd: LlmCommand = { action: "set", color_temp_k: 3000 };
    const result = formatQueuedReply("test", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toContain("warm");
    expect(lines[2]).toContain("warm");
  });

  it("3001 K → neutral", () => {
    const cmd: LlmCommand = { action: "set", color_temp_k: 3001 };
    const result = formatQueuedReply("test", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toContain("neutral");
    expect(lines[2]).toContain("neutral");
  });

  it("4500 K → neutral", () => {
    const cmd: LlmCommand = { action: "set", color_temp_k: 4500 };
    const result = formatQueuedReply("test", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toContain("neutral");
    expect(lines[2]).toContain("neutral");
  });

  it("4501 K → cool", () => {
    const cmd: LlmCommand = { action: "set", color_temp_k: 4501 };
    const result = formatQueuedReply("test", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toContain("cool");
    expect(lines[2]).toContain("cool");
  });

  it("5500 K → cool", () => {
    const cmd: LlmCommand = { action: "set", color_temp_k: 5500 };
    const result = formatQueuedReply("test", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toContain("cool");
    expect(lines[2]).toContain("cool");
  });

  it("5501 K → daylight", () => {
    const cmd: LlmCommand = { action: "set", color_temp_k: 5501 };
    const result = formatQueuedReply("test", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toContain("daylight");
    expect(lines[2]).toContain("daylight");
  });

  it("6500 K → daylight", () => {
    const cmd: LlmCommand = { action: "set", color_temp_k: 6500 };
    const result = formatQueuedReply("test", cmd);
    const lines = result.split("\n");
    expect(lines[1]).toContain("daylight");
    expect(lines[2]).toContain("daylight");
  });
});

// ---------------------------------------------------------------------------
// Request text normalisation (shared between both formatters)
// ---------------------------------------------------------------------------
describe("request text normalisation in formatQueuedReply", () => {
  it("collapses newlines and tabs into single spaces", () => {
    const cmd: LlmCommand = { action: "on" };
    const result = formatQueuedReply("on\n\tthe\r\nlamp", cmd);
    const lines = result.split("\n");
    expect(lines[0]).toBe('Got request — "on the lamp"');
  });

  it("truncates at 200 chars with ellipsis", () => {
    const long = "x".repeat(205);
    const cmd: LlmCommand = { action: "off" };
    const result = formatQueuedReply(long, cmd);
    const lines = result.split("\n");
    expect(lines[0]).toBe(`Got request — "${"x".repeat(200)}…"`);
  });
});

// ---------------------------------------------------------------------------
// Empty-string request body
// ---------------------------------------------------------------------------
describe("empty-string request body", () => {
  it("formatUnparseableReply echoes empty string verbatim", () => {
    const result = formatUnparseableReply("");
    const lines = result.split("\n");
    expect(lines[0]).toBe('Got request — ""');
  });

  it("formatQueuedReply echoes empty string verbatim", () => {
    const cmd: LlmCommand = { action: "on" };
    const result = formatQueuedReply("", cmd);
    const lines = result.split("\n");
    expect(lines[0]).toBe('Got request — ""');
  });
});
