import { describe, expect, it } from "vitest";
import { parseLlmToolUse, extractCommand, makeLlmClient, type LlmClient } from "../src/llm";

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

function fakeFetch(impl: (url: string, init: RequestInit) => Response) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fn = (async (url: unknown, init: unknown) => {
    calls.push({ url: String(url), init: init as RequestInit });
    return impl(String(url), init as RequestInit);
  }) as unknown as typeof fetch;
  return Object.assign(fn, { calls });
}

const env = { ANTHROPIC_API_KEY: "sk-test" } as { ANTHROPIC_API_KEY: string };

describe("makeLlmClient", () => {
  it("posts to the Messages API with model, auth headers, and forced tool use", async () => {
    const f = fakeFetch(() =>
      new Response(JSON.stringify({
        content: [{ type: "tool_use", name: "set_lamp", input: { action: "on", brightness: 40 } }],
      }), { status: 200 }),
    );
    const client = makeLlmClient(env, f);
    const out = await client.complete("on 40%", false);

    expect(out).toEqual({ action: "on", brightness: 40 });
    const call = f.calls[0];
    if (!call) throw new Error("expected a fetch call");
    const { url, init } = call;
    expect(url).toBe("https://api.anthropic.com/v1/messages");
    const headers = init.headers as Record<string, string>;
    expect(headers["x-api-key"]).toBe("sk-test");
    expect(headers["anthropic-version"]).toBe("2023-06-01");
    const body = JSON.parse(init.body as string);
    expect(body.model).toBe("claude-haiku-4-5");
    expect(body.tool_choice).toEqual({ type: "tool", name: "set_lamp" });
    expect(body.messages).toEqual([{ role: "user", content: "on 40%" }]);
  });

  it("returns null when the model emits no set_lamp tool_use", async () => {
    const f = fakeFetch(() =>
      new Response(JSON.stringify({ content: [{ type: "text", text: "huh?" }] }), { status: 200 }),
    );
    expect(await makeLlmClient(env, f).complete("???", false)).toBeNull();
  });

  it("throws on a non-2xx response", async () => {
    const f = fakeFetch(() => new Response("overloaded", { status: 529 }));
    await expect(makeLlmClient(env, f).complete("on", false)).rejects.toThrow(/529/);
  });

  it("appends the strict suffix to body.system when strict=true", async () => {
    const f = fakeFetch(() =>
      new Response(JSON.stringify({
        content: [{ type: "tool_use", name: "set_lamp", input: { action: "off" } }],
      }), { status: 200 }),
    );
    await makeLlmClient(env, f).complete("on", true);
    const call = f.calls[0];
    if (!call) throw new Error("expected a fetch call");
    const body = JSON.parse(call.init.body as string);
    expect(body.system).toContain(
      "Be precise: respond ONLY with a set_lamp tool call whose fields are strictly within range.",
    );
  });
});
