import { describe, expect, it } from "vitest";
import { parseLlmToolUse, extractCommand, type LlmClient } from "../src/llm";

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

function stubClient(responses: unknown[]): LlmClient & { calls: boolean[] } {
  const queue = [...responses];
  const calls: boolean[] = [];
  return {
    calls,
    async complete(_body: string, strict: boolean) {
      calls.push(strict);
      if (queue.length === 0) throw new Error("no more stubbed responses");
      return queue.shift();
    },
  };
}

describe("extractCommand", () => {
  it("returns the command on the first valid response (no retry)", async () => {
    const client = stubClient([{ action: "on", brightness: 30 }]);
    expect(await extractCommand("on 30%", client)).toEqual({ action: "on", brightness: 30 });
    expect(client.calls).toEqual([false]); // only the non-strict attempt
  });

  it("retries once with strict=true when the first response is invalid", async () => {
    const client = stubClient([{ action: "nonsense" }, { action: "off" }]);
    expect(await extractCommand("turn off", client)).toEqual({ action: "off" });
    expect(client.calls).toEqual([false, true]);
  });

  it("returns null after two invalid responses", async () => {
    const client = stubClient([{ action: "bad" }, { foo: 1 }]);
    expect(await extractCommand("???", client)).toBeNull();
    expect(client.calls).toEqual([false, true]);
  });

  it("propagates a transport error (does not swallow it)", async () => {
    const client: LlmClient = {
      async complete() { throw new Error("anthropic 500"); },
    };
    await expect(extractCommand("on", client)).rejects.toThrow("anthropic 500");
  });
});
