import { describe, expect, it } from "vitest";
import worker from "../src/index";

function fakeKV(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    async list({ prefix }: { prefix: string }) {
      return { keys: [...store.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true, cursor: "" };
    },
    async get(key: string) { return store.get(key) ?? null; },
    async delete(key: string) { store.delete(key); },
  };
}

function env(kv = fakeKV()) {
  return { MAC_SHARED_SECRET: "s3cret", COMMANDS: kv } as any;
}

const auth = { Authorization: "Bearer s3cret" };

describe("GET /commands", () => {
  it("401 without a token", async () => {
    const res = await worker.fetch(new Request("https://x/commands"), env());
    expect(res.status).toBe(401);
  });

  it("returns the queued commands wrapped in {commands}", async () => {
    const kv = fakeKV({
      "command:a": JSON.stringify({
        id: "a", action: "on", brightness: 30, color_temp_k: 2700,
        created_at: "2026-05-31T10:00:00Z", source_msg_id: "m",
      }),
    });
    const res = await worker.fetch(new Request("https://x/commands", { headers: auth }), env(kv));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual({
      commands: [{
        id: "a", action: "on", brightness: 30, color_temp_k: 2700,
        created_at: "2026-05-31T10:00:00Z", source_msg_id: "m",
      }],
    });
  });

  it("drops malformed entries rather than 500ing", async () => {
    const kv = fakeKV({ "command:bad": "{ not json" });
    const res = await worker.fetch(new Request("https://x/commands", { headers: auth }), env(kv));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ commands: [] });
  });
});
