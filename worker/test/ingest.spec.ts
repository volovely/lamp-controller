import { describe, expect, it } from "vitest";
import { handleIngest, type IngestDeps } from "../src/ingest";
import type { LlmCommand } from "../src/schema";

function fakeKV(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    async get(key: string) { return store.get(key) ?? null; },
    async put(key: string, value: string) { store.set(key, value); },
  };
}

function env(kv = fakeKV()) {
  return { RELAY_SHARED_SECRET: "relay-secret", COMMANDS: kv } as any;
}

function deps(over: Partial<IngestDeps> = {}): IngestDeps {
  return {
    extract: async () => ({ action: "on", brightness: 30 }) as LlmCommand,
    uuid: () => "fixed-uuid",
    now: () => "2026-06-13T10:00:00.000Z",
    ...over,
  };
}

function post(body: unknown, auth = "Bearer relay-secret") {
  return new Request("https://x/ingest", {
    method: "POST",
    headers: { Authorization: auth, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

const validBody = { msgId: "m1", from: "me@gmail.com", subject: "lamp", body: "on 30%" };

describe("POST /ingest", () => {
  it("401s without a valid relay token", async () => {
    const res = await handleIngest(post(validBody, "Bearer wrong"), env(), deps());
    expect(res.status).toBe(401);
  });

  it("400s on a body missing msgId", async () => {
    const res = await handleIngest(post({ body: "on" }), env(), deps());
    expect(res.status).toBe(400);
  });

  it("400s when msgId is an empty string", async () => {
    const res = await handleIngest(post({ msgId: "", body: "on" }), env(), deps());
    expect(res.status).toBe(400);
  });

  it("queues a valid command and writes KV", async () => {
    const kv = fakeKV();
    const res = await handleIngest(post(validBody), env(kv), deps());
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json.status).toBe("queued");
    expect(json.command).toEqual({ action: "on", brightness: 30 });
    expect(json.reply).toBeNull();
    expect(JSON.parse(kv.store.get("command:fixed-uuid")!)).toEqual({
      id: "fixed-uuid", action: "on", brightness: 30,
      created_at: "2026-06-13T10:00:00.000Z", source_msg_id: "m1",
    });
    expect(kv.store.get("seen:m1")).toBe("1");
  });

  it("returns duplicate when seen:<msgId> already exists (no new command)", async () => {
    const kv = fakeKV({ "seen:m1": "1" });
    let extractCalled = false;
    const res = await handleIngest(post(validBody), env(kv),
      deps({ extract: async () => { extractCalled = true; return null; } }));
    const json = await res.json();
    expect(json.status).toBe("duplicate");
    expect(res.status).toBe(200);
    expect(extractCalled).toBe(false); // dedupe short-circuits before the LLM
    expect([...kv.store.keys()].some((k) => k.startsWith("command:"))).toBe(false);
  });

  it("returns unparseable + a reply and marks seen when extraction fails", async () => {
    const kv = fakeKV();
    const res = await handleIngest(post(validBody), env(kv),
      deps({ extract: async () => null }));
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json.status).toBe("unparseable");
    expect(json.reply).toMatch(/couldn't understand/i);
    expect(kv.store.get("seen:m1")).toBe("1");
    expect([...kv.store.keys()].some((k) => k.startsWith("command:"))).toBe(false);
  });

  it("returns error + 5xx and does NOT mark seen when extraction throws", async () => {
    const kv = fakeKV();
    const res = await handleIngest(post(validBody), env(kv),
      deps({ extract: async () => { throw new Error("anthropic 529"); } }));
    expect(res.status).toBe(502);
    const json = await res.json();
    expect(json.status).toBe("error");
    expect(kv.store.get("seen:m1")).toBeUndefined();
  });
});
