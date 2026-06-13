import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";

/** Parse a Response body as a plain record (tests only — we control all responses). */
async function body(res: Response): Promise<Record<string, unknown>> {
  return (await res.json()) as Record<string, unknown>;
}

function fakeKV() {
  const store = new Map<string, string>();
  return {
    store,
    async list({ prefix }: { prefix: string }) {
      return {
        keys: [...store.keys()]
          .filter((k) => k.startsWith(prefix))
          .map((name) => ({ name })),
        list_complete: true,
        cursor: "",
      };
    },
    async get(key: string) { return store.get(key) ?? null; },
    async put(key: string, value: string) { store.set(key, value); },
    async delete(key: string) { store.delete(key); },
  };
}

function env(kv = fakeKV()) {
  return {
    MAC_SHARED_SECRET: "mac",
    RELAY_SHARED_SECRET: "relay",
    ANTHROPIC_API_KEY: "sk",
    COMMANDS: kv,
  } as any;
}

function post(body: unknown) {
  return new Request("https://x/ingest", {
    method: "POST",
    headers: { Authorization: "Bearer relay", "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

afterEach(() => { vi.unstubAllGlobals(); });

describe("worker.fetch routing for /ingest", () => {
  it("routes a valid ingest through to a queued command", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () =>
        new Response(
          JSON.stringify({
            content: [
              {
                type: "tool_use",
                name: "set_lamp",
                input: { action: "on", brightness: 50 },
              },
            ],
          }),
          { status: 200 },
        ),
      ),
    );
    const kv = fakeKV();
    const res = await worker.fetch(
      post({ msgId: "m9", from: "me@x.com", subject: "lamp", body: "on 50%" }),
      env(kv),
    );
    expect(res.status).toBe(200);
    expect((await body(res)).status).toBe("queued");
    expect([...kv.store.keys()].some((k) => k.startsWith("command:"))).toBe(true);
  });

  it("401s when the relay bearer token is wrong", async () => {
    const res = await worker.fetch(
      new Request("https://x/ingest", {
        method: "POST",
        headers: { Authorization: "Bearer bad-token", "content-type": "application/json" },
        body: JSON.stringify({ msgId: "m1", body: "on" }),
      }),
      env(),
    );
    expect(res.status).toBe(401);
  });

  it("still 404s unknown paths", async () => {
    const res = await worker.fetch(new Request("https://x/nope"), env());
    expect(res.status).toBe(404);
  });

  it("returns duplicate for a pre-seen msgId without hitting Anthropic", async () => {
    const kv = fakeKV();
    kv.store.set("seen:dup-msg", "1");
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    const res = await worker.fetch(
      post({ msgId: "dup-msg", from: "me@x.com", subject: "lamp", body: "on" }),
      env(kv),
    );
    expect(res.status).toBe(200);
    expect((await body(res)).status).toBe("duplicate");
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});
