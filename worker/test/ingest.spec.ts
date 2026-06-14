import { describe, expect, it } from "vitest";
import { handleIngest, type IngestDeps } from "../src/ingest";
import type { LlmCommand } from "../src/schema";

/** Parse a Response body as a plain record (tests only — we control all responses). */
async function body(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

function fakeKV(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    async get(key: string) { return store.get(key) ?? null; },
    async put(key: string, value: string, _options?: unknown) { store.set(key, value); },
  };
}

/** A fakeKV whose get or put throws for keys matching a prefix. */
function fakeKVThrowingOn(prefix: string, initial: Record<string, string> = {}, { throwOnGet = false } = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    async get(key: string) {
      if (throwOnGet && key.startsWith(prefix)) throw new Error(`simulated KV get error for ${key}`);
      return store.get(key) ?? null;
    },
    async put(key: string, value: string, _options?: unknown) {
      if (!throwOnGet && key.startsWith(prefix)) throw new Error(`simulated KV error for ${key}`);
      store.set(key, value);
    },
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

  it("queues a valid command and writes KV, reply contains processing log", async () => {
    const kv = fakeKV();
    const res = await handleIngest(post(validBody), env(kv), deps());
    expect(res.status).toBe(200);
    const json = await body(res);
    expect(json.status).toBe("queued");
    expect(json.command).toEqual({ action: "on", brightness: 30 });
    // reply must now be a processing-log string, not null
    expect(typeof json.reply).toBe("string");
    const lines = (json.reply as string).split("\n");
    expect(lines).toHaveLength(3);
    expect(lines[0]).toMatch(/^Got request —/);
    expect(lines[1]).toMatch(/^Got response from the model —/);
    expect(lines[2]).toMatch(/^Executing —/);
    // spot-check the echoed request body (validBody.body is "on 30%")
    expect(lines[0]).toContain("on 30%");
    // spot-check the command details
    expect(lines[1]).toContain("on");
    expect(lines[1]).toContain("brightness 30");
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
    const json = await body(res);
    expect(json.status).toBe("duplicate");
    expect(res.status).toBe(200);
    expect(extractCalled).toBe(false); // dedupe short-circuits before the LLM
    expect([...kv.store.keys()].some((k) => k.startsWith("command:"))).toBe(false);
  });

  it("returns 502 and status=error when hasSeen KV read throws, and does NOT call extract", async () => {
    const kv = fakeKVThrowingOn("seen:", {}, { throwOnGet: true });
    let extractCalled = false;
    const res = await handleIngest(post(validBody), env(kv),
      deps({ extract: async () => { extractCalled = true; return null; } }));
    expect(res.status).toBe(502);
    const b = await body(res);
    expect(b.status).toBe("error");
    expect(b.reply).toBeNull();
    expect(extractCalled).toBe(false);
  });

  it("returns unparseable + a two-line reply and marks seen when extraction fails", async () => {
    const kv = fakeKV();
    const res = await handleIngest(post(validBody), env(kv),
      deps({ extract: async () => null }));
    expect(res.status).toBe(200);
    const json = await body(res);
    expect(json.status).toBe("unparseable");
    expect(typeof json.reply).toBe("string");
    const lines = (json.reply as string).split("\n");
    expect(lines).toHaveLength(2);
    expect(lines[0]).toMatch(/^Got request —/);
    // validBody.body is "on 30%" — check it's echoed
    expect(lines[0]).toContain("on 30%");
    expect(lines[1]).toMatch(/couldn't understand/i);
    expect(kv.store.get("seen:m1")).toBe("1");
    expect([...kv.store.keys()].some((k) => k.startsWith("command:"))).toBe(false);
  });

  it("returns error + 5xx and does NOT mark seen when extraction throws", async () => {
    const kv = fakeKV();
    const res = await handleIngest(post(validBody), env(kv),
      deps({ extract: async () => { throw new Error("anthropic 529"); } }));
    expect(res.status).toBe(502);
    const json = await body(res);
    expect(json.status).toBe("error");
    expect(kv.store.get("seen:m1")).toBeUndefined();
  });

  it("returns 502 error when putCommand throws, and does NOT write seen:", async () => {
    const kv = fakeKVThrowingOn("command:");
    let extractCalled = false;
    const res = await handleIngest(post(validBody), env(kv),
      deps({ extract: async (t) => { extractCalled = true; return { action: "on", brightness: 30 } as LlmCommand; } }));
    expect(res.status).toBe(502);
    const b = await body(res);
    expect(b.status).toBe("error");
    expect(b).not.toHaveProperty("command");
    expect(extractCalled).toBe(true); // extract was called before putCommand threw
    expect([...kv.store.keys()].some((k) => k.startsWith("command:"))).toBe(false);
    expect(kv.store.get("seen:m1")).toBeUndefined();
  });

  it("returns 200 queued when markSeen throws, because command is already written", async () => {
    const kv = fakeKVThrowingOn("seen:");
    const res = await handleIngest(post(validBody), env(kv), deps());
    expect(res.status).toBe(200);
    const b = await body(res);
    expect(b.status).toBe("queued");
    expect(b.command).toEqual({ action: "on", brightness: 30 });
    // command: key was written successfully before markSeen was attempted
    expect([...kv.store.keys()].some((k) => k.startsWith("command:"))).toBe(true);
    // seen: write failed, but that is non-fatal
    expect(kv.store.get("seen:m1")).toBeUndefined();
  });

  it("accepts an empty-string body and reaches extract (body is not required non-empty)", async () => {
    let extractCalledWith: string | undefined;
    const kv = fakeKV();
    const res = await handleIngest(
      post({ msgId: "m2", body: "" }),
      env(kv),
      deps({ extract: async (t) => { extractCalledWith = t; return null; } }),
    );
    // Not a 400 — empty body is allowed; the LLM may handle it
    expect(res.status).toBe(200);
    expect(extractCalledWith).toBe("");
    const b = await body(res);
    expect(b.status).toBe("unparseable");
    // seen:m2 must be written on the unparseable path so double-delivery is suppressed
    expect(kv.store.get("seen:m2")).toBe("1");
  });

  it("returns 502 error and does NOT write seen: when markSeen throws on unparseable path", async () => {
    const kv = fakeKVThrowingOn("seen:");
    const res = await handleIngest(post(validBody), env(kv),
      deps({ extract: async () => null }));
    expect(res.status).toBe(502);
    const b = await body(res);
    expect(b.status).toBe("error");
    expect(b.reply).toBeNull();
    // nothing committed — no command: key, no seen: key
    expect([...kv.store.keys()].some((k) => k.startsWith("command:"))).toBe(false);
    expect(kv.store.get("seen:m1")).toBeUndefined();
  });
});
