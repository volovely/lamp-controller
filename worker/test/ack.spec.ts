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

function env(kv: ReturnType<typeof fakeKV>) {
  return { MAC_SHARED_SECRET: "s3cret", COMMANDS: kv } as any;
}

const auth = { Authorization: "Bearer s3cret", "content-type": "application/json" };

describe("POST /ack", () => {
  it("401 without a token", async () => {
    const kv = fakeKV();
    const res = await worker.fetch(
      new Request("https://x/ack", { method: "POST", body: JSON.stringify({ ids: ["a"] }) }),
      env(kv),
    );
    expect(res.status).toBe(401);
  });

  it("deletes the named keys and returns 204", async () => {
    const kv = fakeKV({ "command:a": "{}", "command:b": "{}", "command:c": "{}" });
    const res = await worker.fetch(
      new Request("https://x/ack", { method: "POST", headers: auth, body: JSON.stringify({ ids: ["a", "b"] }) }),
      env(kv),
    );
    expect(res.status).toBe(204);
    expect([...kv.store.keys()]).toEqual(["command:c"]);
  });

  it("400 on a malformed body", async () => {
    const kv = fakeKV();
    const res = await worker.fetch(
      new Request("https://x/ack", { method: "POST", headers: auth, body: "{ not json" }),
      env(kv),
    );
    expect(res.status).toBe(400);
  });

  it("400 when ids is not an array of strings", async () => {
    const kv = fakeKV();
    const res = await worker.fetch(
      new Request("https://x/ack", { method: "POST", headers: auth, body: JSON.stringify({ ids: "a" }) }),
      env(kv),
    );
    expect(res.status).toBe(400);
  });
});
