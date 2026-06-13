# Stage 3 — Email + LLM (Apps Script relay) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Spec (read first, work from it as the contract):** `docs/superpowers/specs/2026-06-13-stage-3-email-llm-design.md`. When dispatching sub-agents, always reference that spec.

**Goal:** Turn an email sent to `v.lamp.controller@gmail.com` into a queued lamp `Command`, via a Google Apps Script relay that POSTs unread `subject:lamp` mail to a new Worker `POST /ingest` route, which extracts intent with Claude Haiku 4.5 and writes `command:<uuid>` to KV.

**Architecture:** Ingestion is push-based, not cron/IMAP. An Apps Script bound to the lamp Gmail owns all mail mutations (mark-read, reply). The Cloudflare Worker is pure decision logic: verify a relay bearer secret → dedupe on `seen:<msgId>` → call Anthropic (forced tool use) → write KV → return a verdict the relay acts on. Builds on the existing Stage 2 Worker (`worker/src/{index,auth,kv,schema}.ts`, vitest) and the `shared/command-schema.json` contract.

**Tech Stack:** TypeScript Cloudflare Worker (wrangler, KV, vitest, zod), raw `fetch` to the Anthropic Messages API (no SDK dependency — matches the worker's minimal-deps style), Google Apps Script (`GmailApp` + time trigger).

---

## File structure

| File | Responsibility | Action |
|---|---|---|
| `worker/src/schema.ts` | Add `LlmCommandSchema` / `LlmCommand` (the model-output subset) next to `CommandSchema` | Modify |
| `worker/src/llm.ts` | `parseLlmToolUse` (pure clamp+validate), `extractCommand` (retry-once over an injected `LlmClient`), `makeLlmClient` (live Anthropic fetch) | Create |
| `worker/src/kv.ts` | Add `putCommand`, `hasSeen`, `markSeen` | Modify |
| `worker/src/auth.ts` | Extract a shared `bearerGuard`; add `requireRelayBearer` | Modify |
| `worker/src/ingest.ts` | `handleIngest(request, env, deps)` — the `POST /ingest` handler | Create |
| `worker/src/index.ts` | Route `POST /ingest`; add `ANTHROPIC_API_KEY` + `RELAY_SHARED_SECRET` to `Env`; build live deps; remove the dead `scheduled` handler | Modify |
| `worker/wrangler.toml` | Remove the cron trigger; document the two new secrets | Modify |
| `worker/test/*.spec.ts` | New specs per module | Create |
| `gmail-relay/Code.gs` | The Apps Script relay | Create |
| `gmail-relay/README.md` | Deploy instructions for the relay | Create |
| `docs/ops/first-time-setup.md` | New "Stage 3" section | Modify |
| `docs/ops/secrets.md` | Add `ANTHROPIC_API_KEY`, `RELAY_SHARED_SECRET` | Modify |

**Run all worker commands from `worker/`.** Tests: `cd worker && pnpm test`. Single file: `pnpm test <file>`. Typecheck: `pnpm typecheck`.

---

### Task 1: `LlmCommandSchema` — the model-output subset

**Files:**
- Modify: `worker/src/schema.ts`
- Test: `worker/test/schema.spec.ts` (append)

- [ ] **Step 1: Write the failing test**

Append to `worker/test/schema.spec.ts`:

```typescript
import { LlmCommandSchema } from "../src/schema";

describe("LlmCommandSchema", () => {
  it("accepts a bare on with no fields", () => {
    expect(LlmCommandSchema.safeParse({ action: "on" }).success).toBe(true);
  });

  it("accepts on with brightness + color_temp_k", () => {
    const r = LlmCommandSchema.safeParse({ action: "on", brightness: 30, color_temp_k: 2700 });
    expect(r.success).toBe(true);
  });

  it("rejects an unknown action", () => {
    expect(LlmCommandSchema.safeParse({ action: "dim" }).success).toBe(false);
  });

  it("rejects out-of-range brightness", () => {
    expect(LlmCommandSchema.safeParse({ action: "on", brightness: 500 }).success).toBe(false);
  });

  it("rejects unknown extra keys (strict)", () => {
    expect(LlmCommandSchema.safeParse({ action: "on", id: "x" }).success).toBe(false);
  });
});
```

Note: the existing `schema.spec.ts` already imports from vitest and `../src/schema`; reuse those imports rather than re-importing `describe`/`it`/`expect`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd worker && pnpm test schema`
Expected: FAIL — `LlmCommandSchema` is not exported.

- [ ] **Step 3: Add the schema**

Append to `worker/src/schema.ts` (after the existing `parseCommand`):

```typescript
// The subset the LLM is asked to produce; the Worker adds id/created_at/source_msg_id.
export const LlmCommandSchema = z
  .object({
    action: z.enum(["on", "off", "set"]),
    brightness: z.number().int().min(0).max(100).optional(),
    color_temp_k: z.number().int().min(2700).max(6500).optional(),
  })
  .strict();

export type LlmCommand = z.infer<typeof LlmCommandSchema>;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd worker && pnpm test schema`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/src/schema.ts worker/test/schema.spec.ts
git commit -m "feat(worker): LlmCommandSchema for LLM-extracted command subset"
```

---

### Task 2: `parseLlmToolUse` — pure clamp + validate

**Files:**
- Create: `worker/src/llm.ts`
- Test: `worker/test/llm.spec.ts`

- [ ] **Step 1: Write the failing test**

Create `worker/test/llm.spec.ts`:

```typescript
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd worker && pnpm test llm`
Expected: FAIL — `../src/llm` does not exist.

- [ ] **Step 3: Create `worker/src/llm.ts` with the pure parser**

```typescript
import { LlmCommandSchema, type LlmCommand } from "./schema";

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

/**
 * Normalize a raw tool-use input into an LlmCommand, or null if it doesn't conform.
 * Clamps brightness to 0-100 and color_temp_k to 2700-6500 (the model may overshoot
 * a named bucket); strips brightness/color from "off".
 */
export function parseLlmToolUse(raw: unknown): LlmCommand | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;

  const candidate: Record<string, unknown> = { action: r.action };
  if (r.action !== "off") {
    if (typeof r.brightness === "number") {
      candidate.brightness = clamp(Math.round(r.brightness), 0, 100);
    }
    if (typeof r.color_temp_k === "number") {
      candidate.color_temp_k = clamp(Math.round(r.color_temp_k), 2700, 6500);
    }
  }

  const result = LlmCommandSchema.safeParse(candidate);
  return result.success ? result.data : null;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd worker && pnpm test llm`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/src/llm.ts worker/test/llm.spec.ts
git commit -m "feat(worker): parseLlmToolUse — clamp + validate LLM output"
```

---

### Task 3: `extractCommand` — retry once over an injected client

**Files:**
- Modify: `worker/src/llm.ts`
- Test: `worker/test/llm.spec.ts` (append)

- [ ] **Step 1: Write the failing test**

Append to `worker/test/llm.spec.ts`:

```typescript
import { extractCommand, type LlmClient } from "../src/llm";

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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd worker && pnpm test llm`
Expected: FAIL — `extractCommand` / `LlmClient` not exported.

- [ ] **Step 3: Add `LlmClient` + `extractCommand` to `worker/src/llm.ts`**

Append:

```typescript
export interface LlmClient {
  /**
   * Returns the model's raw tool-use input object (or null if the model produced
   * no usable tool call). Throws on transport / API errors so the caller can
   * distinguish "couldn't reach the model" from "model produced garbage".
   */
  complete(emailBody: string, strict: boolean): Promise<unknown>;
}

/**
 * Extract a command from the email body. Tries once normally; on an invalid
 * result, retries once with a stricter instruction. Returns null if both
 * attempts fail to validate. Re-throws transport errors from the client.
 */
export async function extractCommand(
  emailBody: string,
  client: LlmClient,
): Promise<LlmCommand | null> {
  for (const strict of [false, true]) {
    const raw = await client.complete(emailBody, strict);
    const command = parseLlmToolUse(raw);
    if (command) return command;
  }
  return null;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd worker && pnpm test llm`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/src/llm.ts worker/test/llm.spec.ts
git commit -m "feat(worker): extractCommand with retry-once over an LlmClient"
```

---

### Task 4: `makeLlmClient` — live Anthropic Messages call

**Files:**
- Modify: `worker/src/llm.ts`
- Test: `worker/test/llm.spec.ts` (append)

This locks the request shape (model id, headers, forced tool use) and the 5xx → throw behavior, using an injected `fetch` so no network is hit.

- [ ] **Step 1: Write the failing test**

Append to `worker/test/llm.spec.ts`:

```typescript
import { makeLlmClient } from "../src/llm";

function fakeFetch(impl: (url: string, init: RequestInit) => Response) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fn = (async (url: any, init: any) => {
    calls.push({ url: String(url), init });
    return impl(String(url), init);
  }) as unknown as typeof fetch;
  return Object.assign(fn, { calls });
}

const env = { ANTHROPIC_API_KEY: "sk-test" } as any;

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
    const { url, init } = f.calls[0];
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
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd worker && pnpm test llm`
Expected: FAIL — `makeLlmClient` not exported.

- [ ] **Step 3: Add the live client to `worker/src/llm.ts`**

Append:

```typescript
export interface LlmEnv {
  ANTHROPIC_API_KEY: string;
}

const SET_LAMP_TOOL = {
  name: "set_lamp",
  description: "Apply a lamp command parsed from the user's natural-language request.",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      action: {
        type: "string",
        enum: ["on", "off", "set"],
        description: "on/off toggle power; set adjusts brightness/color (also turns the lamp on).",
      },
      brightness: { type: "integer", minimum: 0, maximum: 100, description: "Brightness percent." },
      color_temp_k: {
        type: "integer",
        minimum: 2700,
        maximum: 6500,
        description: "Color temperature in Kelvin: warm≈2700, neutral≈4000, cool≈5500, daylight≈6500.",
      },
    },
    required: ["action"],
  },
} as const;

const SYSTEM = [
  "You translate a short natural-language request about a desk lamp into a single set_lamp tool call.",
  "The lamp is tunable white: brightness 0-100 percent and color temperature 2700K (warm) to 6500K (cool).",
  "Map fuzzy words to Kelvin: warm≈2700, neutral≈4000, cool≈5500, daylight≈6500.",
  'Use "off" for turning the lamp off (no other fields). Use "on" to turn it on (optionally with brightness/color).',
  'Use "set" to adjust brightness/color of an already-on lamp.',
  "Always respond by calling set_lamp. Never answer in prose.",
].join(" ");

const STRICT_SUFFIX =
  " The previous attempt was invalid. Respond ONLY with a set_lamp tool call whose fields are within range.";

/** Live LlmClient backed by the Anthropic Messages API. `fetchImpl` is injectable for tests. */
export function makeLlmClient(env: LlmEnv, fetchImpl: typeof fetch = fetch): LlmClient {
  return {
    async complete(emailBody: string, strict: boolean): Promise<unknown> {
      const res = await fetchImpl("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "x-api-key": env.ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          model: "claude-haiku-4-5",
          max_tokens: 256,
          system: strict ? SYSTEM + STRICT_SUFFIX : SYSTEM,
          tools: [SET_LAMP_TOOL],
          tool_choice: { type: "tool", name: "set_lamp" },
          messages: [{ role: "user", content: emailBody }],
        }),
      });
      if (!res.ok) throw new Error(`anthropic request failed: ${res.status}`);
      const data = (await res.json()) as { content?: Array<Record<string, unknown>> };
      const toolUse = (data.content ?? []).find(
        (b) => b.type === "tool_use" && b.name === "set_lamp",
      );
      return toolUse?.input ?? null;
    },
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd worker && pnpm test llm`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/src/llm.ts worker/test/llm.spec.ts
git commit -m "feat(worker): makeLlmClient — Haiku 4.5 forced-tool-use extraction"
```

---

### Task 5: KV helpers — `putCommand`, `hasSeen`, `markSeen`

**Files:**
- Modify: `worker/src/kv.ts`
- Test: `worker/test/kv.spec.ts` (append)

- [ ] **Step 1: Write the failing test**

Append to `worker/test/kv.spec.ts`. First, a fake KV that supports `put` with options (the existing `kv.spec.ts` fake may not):

```typescript
import { putCommand, hasSeen, markSeen } from "../src/kv";

function fakeKVWithPut(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  const puts: Array<{ key: string; options?: KVNamespacePutOptions }> = [];
  return {
    store,
    puts,
    async get(key: string) { return store.get(key) ?? null; },
    async put(key: string, value: string, options?: KVNamespacePutOptions) {
      store.set(key, value);
      puts.push({ key, options });
    },
  };
}

describe("putCommand / hasSeen / markSeen", () => {
  it("putCommand writes command:<id> with the serialized command", async () => {
    const kv = fakeKVWithPut();
    const cmd = {
      id: "abc", action: "on" as const, brightness: 30,
      created_at: "2026-06-13T10:00:00.000Z", source_msg_id: "m1",
    };
    await putCommand({ COMMANDS: kv } as any, cmd);
    expect(JSON.parse(kv.store.get("command:abc")!)).toEqual(cmd);
  });

  it("hasSeen reflects whether seen:<msgId> exists", async () => {
    const kv = fakeKVWithPut({ "seen:known": "1" });
    expect(await hasSeen({ COMMANDS: kv } as any, "known")).toBe(true);
    expect(await hasSeen({ COMMANDS: kv } as any, "unknown")).toBe(false);
  });

  it("markSeen writes seen:<msgId> with a 24h TTL", async () => {
    const kv = fakeKVWithPut();
    await markSeen({ COMMANDS: kv } as any, "m2");
    expect(kv.store.get("seen:m2")).toBe("1");
    expect(kv.puts[0].options?.expirationTtl).toBe(86400);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd worker && pnpm test kv`
Expected: FAIL — helpers not exported.

- [ ] **Step 3: Add the helpers to `worker/src/kv.ts`**

Append (the file already imports `Command` and defines `PREFIX = "command:"` and `KVEnv`):

```typescript
const SEEN_PREFIX = "seen:";
const SEEN_TTL_SECONDS = 86400; // 24h — idempotency backstop; relay mark-read is the primary guard

/** Writes command:<id> with the serialized command. */
export async function putCommand(env: KVEnv, command: Command): Promise<void> {
  await env.COMMANDS.put(`${PREFIX}${command.id}`, JSON.stringify(command));
}

/** True if this Gmail message has already been accepted or rejected. */
export async function hasSeen(env: KVEnv, msgId: string): Promise<boolean> {
  return (await env.COMMANDS.get(`${SEEN_PREFIX}${msgId}`)) !== null;
}

/** Records that this Gmail message was handled, with a TTL so the table self-prunes. */
export async function markSeen(env: KVEnv, msgId: string): Promise<void> {
  await env.COMMANDS.put(`${SEEN_PREFIX}${msgId}`, "1", { expirationTtl: SEEN_TTL_SECONDS });
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd worker && pnpm test kv`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/src/kv.ts worker/test/kv.spec.ts
git commit -m "feat(worker): KV helpers for command write + seen dedupe"
```

---

### Task 6: Relay bearer auth

**Files:**
- Modify: `worker/src/auth.ts`
- Test: `worker/test/auth.spec.ts` (append)

- [ ] **Step 1: Write the failing test**

Append to `worker/test/auth.spec.ts`:

```typescript
import { requireRelayBearer } from "../src/auth";

function req(authHeader?: string) {
  const headers = authHeader ? { Authorization: authHeader } : undefined;
  return new Request("https://x/ingest", { method: "POST", headers });
}

describe("requireRelayBearer", () => {
  it("500s when RELAY_SHARED_SECRET is empty (fails closed)", () => {
    const res = requireRelayBearer(req("Bearer x"), { RELAY_SHARED_SECRET: "" } as any);
    expect(res?.status).toBe(500);
  });

  it("401s without a token", () => {
    const res = requireRelayBearer(req(), { RELAY_SHARED_SECRET: "relay-secret" } as any);
    expect(res?.status).toBe(401);
  });

  it("401s on a wrong token", () => {
    const res = requireRelayBearer(req("Bearer nope"), { RELAY_SHARED_SECRET: "relay-secret" } as any);
    expect(res?.status).toBe(401);
  });

  it("returns null when the token matches", () => {
    const res = requireRelayBearer(req("Bearer relay-secret"), { RELAY_SHARED_SECRET: "relay-secret" } as any);
    expect(res).toBeNull();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd worker && pnpm test auth`
Expected: FAIL — `requireRelayBearer` not exported.

- [ ] **Step 3: Refactor `worker/src/auth.ts` to share a guard**

Replace the body of `requireBearer` with a call to a shared `bearerGuard`, and add `requireRelayBearer`. The existing `timingSafeEqual` stays as-is. New file shape:

```typescript
export interface AuthEnv {
  MAC_SHARED_SECRET: string;
}

export interface RelayAuthEnv {
  RELAY_SHARED_SECRET: string;
}

/** Constant-time string compare (avoids timing leaks on the token). */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Shared bearer check. Returns a 500 Response if the secret is unconfigured,
 * a 401 Response if the request lacks a valid token, or null if authorized.
 */
function bearerGuard(request: Request, secret: string): Response | null {
  if (!secret) return jsonResponse({ error: "server misconfigured" }, 500);
  const header = request.headers.get("Authorization") ?? "";
  const prefix = "Bearer ";
  const ok =
    header.startsWith(prefix) && timingSafeEqual(header.slice(prefix.length), secret);
  return ok ? null : jsonResponse({ error: "unauthorized" }, 401);
}

export function requireBearer(request: Request, env: AuthEnv): Response | null {
  return bearerGuard(request, env.MAC_SHARED_SECRET);
}

export function requireRelayBearer(request: Request, env: RelayAuthEnv): Response | null {
  return bearerGuard(request, env.RELAY_SHARED_SECRET);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd worker && pnpm test auth`
Expected: PASS — both the new `requireRelayBearer` tests and the existing `requireBearer` tests (behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add worker/src/auth.ts worker/test/auth.spec.ts
git commit -m "refactor(worker): share bearerGuard; add requireRelayBearer"
```

---

### Task 7: `POST /ingest` handler

**Files:**
- Create: `worker/src/ingest.ts`
- Test: `worker/test/ingest.spec.ts`

- [ ] **Step 1: Write the failing test**

Create `worker/test/ingest.spec.ts`:

```typescript
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

  it("queues a valid command and writes KV", async () => {
    const kv = fakeKV();
    const res = await handleIngest(post(validBody), env(kv), deps());
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json.status).toBe("queued");
    expect(json.command).toEqual({ action: "on", brightness: 30 });
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
    expect((await res.json()).status).toBe("duplicate");
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
    expect((await res.json()).status).toBe("error");
    expect(kv.store.get("seen:m1")).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd worker && pnpm test ingest`
Expected: FAIL — `../src/ingest` does not exist.

- [ ] **Step 3: Create `worker/src/ingest.ts`**

```typescript
import { requireRelayBearer, type RelayAuthEnv } from "./auth";
import { putCommand, hasSeen, markSeen, type KVEnv } from "./kv";
import { type Command, type LlmCommand } from "./schema";

export type IngestEnv = RelayAuthEnv & KVEnv;

export interface IngestDeps {
  /** Extract a command from the email body; resolves null on unparseable, throws on transport error. */
  extract(body: string): Promise<LlmCommand | null>;
  uuid(): string;
  now(): string;
}

const UNPARSEABLE_REPLY =
  "Couldn't understand that command. Try e.g. 'on, warm, 30%'.";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export async function handleIngest(
  request: Request,
  env: IngestEnv,
  deps: IngestDeps,
): Promise<Response> {
  const unauthorized = requireRelayBearer(request, env);
  if (unauthorized) return unauthorized;

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }
  const { msgId, body: text } = (body ?? {}) as { msgId?: unknown; body?: unknown };
  if (typeof msgId !== "string" || msgId.length === 0 || typeof text !== "string") {
    return json({ error: "msgId and body are required strings" }, 400);
  }

  // Dedupe before spending an LLM call. Relay mark-read is the primary guard.
  if (await hasSeen(env, msgId)) {
    return json({ status: "duplicate", reply: null });
  }

  let extracted: LlmCommand | null;
  try {
    extracted = await deps.extract(text);
  } catch (err) {
    // Transport/API failure: don't mark seen, return 5xx so the relay leaves the
    // message unread and retries on the next tick.
    console.log(`ingest extract error for ${msgId}: ${String(err)}`);
    return json({ status: "error", reply: null }, 502);
  }

  if (extracted === null) {
    await markSeen(env, msgId);
    return json({ status: "unparseable", reply: UNPARSEABLE_REPLY });
  }

  const command: Command = {
    id: deps.uuid(),
    ...extracted,
    created_at: deps.now(),
    source_msg_id: msgId,
  };
  await putCommand(env, command);
  await markSeen(env, msgId);
  return json({ status: "queued", command: extracted, reply: null });
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd worker && pnpm test ingest`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add worker/src/ingest.ts worker/test/ingest.spec.ts
git commit -m "feat(worker): POST /ingest handler (verdict + KV + dedupe)"
```

---

### Task 8: Wire `/ingest` into the Worker entrypoint

**Files:**
- Modify: `worker/src/index.ts`
- Modify: `worker/wrangler.toml`
- Test: `worker/test/ingest_route.spec.ts`

- [ ] **Step 1: Write the failing test (route-level, with a stub fetch for Anthropic)**

Create `worker/test/ingest_route.spec.ts`. This exercises the real wiring in `index.ts` end-to-end except the Anthropic HTTP call, which we stub via the global `fetch`:

```typescript
import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "../src/index";

function fakeKV() {
  const store = new Map<string, string>();
  return {
    store,
    async list({ prefix }: { prefix: string }) {
      return { keys: [...store.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true, cursor: "" };
    },
    async get(key: string) { return store.get(key) ?? null; },
    async put(key: string, value: string) { store.set(key, value); },
    async delete(key: string) { store.delete(key); },
  };
}

function env(kv = fakeKV()) {
  return { MAC_SHARED_SECRET: "mac", RELAY_SHARED_SECRET: "relay", ANTHROPIC_API_KEY: "sk", COMMANDS: kv } as any;
}

function post(body: unknown) {
  return new Request("https://x/ingest", {
    method: "POST",
    headers: { Authorization: "Bearer relay", "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

afterEach(() => vi.unstubAllGlobals());

describe("worker.fetch routing for /ingest", () => {
  it("routes a valid ingest through to a queued command", async () => {
    vi.stubGlobal("fetch", vi.fn(async () =>
      new Response(JSON.stringify({
        content: [{ type: "tool_use", name: "set_lamp", input: { action: "on", brightness: 50 } }],
      }), { status: 200 }),
    ));
    const kv = fakeKV();
    const res = await worker.fetch(post({ msgId: "m9", from: "me@x.com", subject: "lamp", body: "on 50%" }), env(kv));
    expect(res.status).toBe(200);
    expect((await res.json()).status).toBe("queued");
    expect([...kv.store.keys()].some((k) => k.startsWith("command:"))).toBe(true);
  });

  it("still 404s unknown paths", async () => {
    const res = await worker.fetch(new Request("https://x/nope"), env());
    expect(res.status).toBe(404);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd worker && pnpm test ingest_route`
Expected: FAIL — `/ingest` is not routed (returns 404).

- [ ] **Step 3: Wire the route in `worker/src/index.ts`**

Add imports at the top:

```typescript
import { handleIngest, type IngestDeps } from "./ingest";
import { makeLlmClient, extractCommand } from "./llm";
```

Extend the `Env` interface:

```typescript
export interface Env {
  MAC_SHARED_SECRET: string;
  RELAY_SHARED_SECRET: string;
  ANTHROPIC_API_KEY: string;
  COMMANDS: KVNamespace;
}
```

Add the route inside `fetch`, before the final 404 (after the `/ack` block):

```typescript
    if (request.method === "POST" && url.pathname === "/ingest") {
      const client = makeLlmClient(env);
      const deps: IngestDeps = {
        extract: (body) => extractCommand(body, client),
        uuid: () => crypto.randomUUID(),
        now: () => new Date().toISOString(),
      };
      return handleIngest(request, env, deps);
    }
```

Remove the now-dead `scheduled` handler (the `async scheduled(): Promise<void> { ... }` method) — ingestion is push-based via the relay, so there is no cron.

- [ ] **Step 4: Remove the cron trigger from `worker/wrangler.toml`**

Delete the `[triggers]` block and its `crons` line and the comment above it. Add a comment documenting the new secrets near the KV section:

```toml
# Secrets (set once via `wrangler secret put`, never in git):
#   ANTHROPIC_API_KEY    — Claude Haiku 4.5 for intent extraction
#   RELAY_SHARED_SECRET  — bearer the Apps Script relay sends to POST /ingest
#   MAC_SHARED_SECRET    — bearer the Mac agent sends to GET /commands, POST /ack
```

- [ ] **Step 5: Run the test, typecheck, and full suite**

Run: `cd worker && pnpm test ingest_route && pnpm typecheck && pnpm test`
Expected: all PASS. If a pre-existing test referenced `worker.scheduled`, update it to drop that reference (there should be none).

- [ ] **Step 6: Commit**

```bash
git add worker/src/index.ts worker/wrangler.toml worker/test/ingest_route.spec.ts
git commit -m "feat(worker): route POST /ingest; drop cron + scheduled no-op"
```

---

### Task 9: Apps Script relay (`gmail-relay/Code.gs` + README)

**Files:**
- Create: `gmail-relay/Code.gs`
- Create: `gmail-relay/README.md`

Not exercised by CI — verified manually per the README. Write it precisely so it can be pasted as-is.

- [ ] **Step 1: Create `gmail-relay/Code.gs`**

```javascript
/**
 * Lamp controller — Gmail relay.
 * Bound to v.lamp.controller@gmail.com. A 1-minute time trigger runs pollLamp(),
 * which forwards unread "subject:lamp" mail to the Worker's /ingest endpoint and
 * acts on the verdict (mark read; reply on failure). All Gmail mutations live here;
 * the Worker is pure decision logic.
 *
 * Setup: Project Settings → Script Properties:
 *   WORKER_URL    e.g. https://lamp-controller.<subdomain>.workers.dev
 *   RELAY_SECRET  must equal the Worker's RELAY_SHARED_SECRET
 * Then add a time-driven trigger for pollLamp, every 1 minute.
 */

var BATCH = 10;

function pollLamp() {
  var props = PropertiesService.getScriptProperties();
  var workerUrl = props.getProperty('WORKER_URL');
  var relaySecret = props.getProperty('RELAY_SECRET');
  if (!workerUrl || !relaySecret) {
    throw new Error('Set WORKER_URL and RELAY_SECRET in Script Properties.');
  }

  var threads = GmailApp.search('is:unread subject:lamp', 0, BATCH);
  for (var i = 0; i < threads.length; i++) {
    var messages = threads[i].getMessages();
    var msg = messages[messages.length - 1]; // latest message in the thread
    handleMessage(msg, workerUrl, relaySecret);
  }
}

function handleMessage(msg, workerUrl, relaySecret) {
  var payload = {
    msgId: msg.getId(),
    from: msg.getFrom(),
    subject: msg.getSubject(),
    body: msg.getPlainBody(),
  };

  var response;
  try {
    response = UrlFetchApp.fetch(workerUrl + '/ingest', {
      method: 'post',
      contentType: 'application/json',
      headers: { Authorization: 'Bearer ' + relaySecret },
      payload: JSON.stringify(payload),
      muteHttpExceptions: true,
    });
  } catch (e) {
    Logger.log('relay: POST failed for %s: %s (leaving unread)', payload.msgId, e);
    return; // transport failure — leave unread, retry next tick
  }

  var code = response.getResponseCode();
  if (code !== 200) {
    // 5xx (transient), 401 (misconfigured secret), 400 (bad payload) — all left
    // unread so nothing is silently dropped; fix config / retry next tick.
    Logger.log('relay: worker %s for %s (leaving unread)', code, payload.msgId);
    return;
  }

  var verdict = JSON.parse(response.getContentText());
  if (verdict.reply) {
    msg.reply(verdict.reply);
  }
  msg.markRead();
  Logger.log('relay: %s -> %s', payload.msgId, verdict.status);
}
```

- [ ] **Step 2: Create `gmail-relay/README.md`**

```markdown
# Gmail relay (Apps Script)

Forwards unread `subject:lamp` mail in `v.lamp.controller@gmail.com` to the
Worker's `POST /ingest`, then acts on the verdict (mark read; reply on failure).
This is the Stage 3 ingestion path — see
`docs/superpowers/specs/2026-06-13-stage-3-email-llm-design.md`.

## Why Apps Script (not IMAP/OAuth in the Worker)

It runs first-party as the mailbox owner: no GCP project, no OAuth refresh token,
no IMAP client in the Workers runtime. A one-time unverified-app consent is all
that's needed; the trigger then runs as you indefinitely.

## Deploy

1. https://script.google.com → **New project** (signed in as the lamp account).
2. Replace `Code.gs` with this folder's `Code.gs`. Save.
3. **Project Settings → Script properties → Add**:
   - `WORKER_URL` = your Worker origin, no trailing slash
     (e.g. `https://lamp-controller.<subdomain>.workers.dev`).
   - `RELAY_SECRET` = the same value set as the Worker's `RELAY_SHARED_SECRET`.
4. **Triggers** (clock icon) → **Add Trigger**: function `pollLamp`,
   event source *Time-driven*, *Minutes timer*, *Every minute*.
5. The first run prompts for authorization. You'll see
   **"Google hasn't verified this app"** → **Advanced** →
   **Go to <project> (unsafe)** → **Allow**. This is a one-time owner consent.

## Test

Send an email to `v.lamp.controller@gmail.com` with subject `lamp` and body
`on, warm, 30%`. Within ~1 minute the message is marked read and a `command:<uuid>`
appears in KV (`wrangler kv key list --binding COMMANDS`). A nonsense body gets a
"couldn't understand" reply and is marked read.

## Notes

- Batch is capped at 10 threads per tick. Non-`lamp` unread mail is left untouched.
- On a Worker 5xx or network error the message is **left unread** and retried next tick.
- Secrets live only in Script Properties — never commit them.
```

- [ ] **Step 3: Commit**

```bash
git add gmail-relay/Code.gs gmail-relay/README.md
git commit -m "feat(relay): Apps Script Gmail relay + deploy README"
```

---

### Task 10: Ops docs — Stage 3 setup + secrets

**Files:**
- Modify: `docs/ops/first-time-setup.md`
- Modify: `docs/ops/secrets.md`

- [ ] **Step 1: Read both files to match their existing structure**

Run: `cat docs/ops/first-time-setup.md docs/ops/secrets.md`
Note the heading style and how earlier stages/secrets are formatted, then mirror it.

- [ ] **Step 2: Append a Stage 3 section to `docs/ops/first-time-setup.md`**

Add a section (match the file's existing heading level for stages):

```markdown
## Stage 3 — Email + LLM (Apps Script relay)

Human steps to make email control live. Ingestion is the Apps Script relay
(`gmail-relay/`), not IMAP/cron. See
`docs/superpowers/specs/2026-06-13-stage-3-email-llm-design.md`.

1. **Anthropic API key.** Create a key at the Anthropic Console, then:
   `cd worker && wrangler secret put ANTHROPIC_API_KEY`.
2. **Relay shared secret.** Generate a 256-bit secret
   (`openssl rand -hex 32`). Set it on the Worker:
   `wrangler secret put RELAY_SHARED_SECRET`. Keep the value — the relay needs it.
3. **Deploy the Worker** (so `/ingest` is live): `wrangler deploy` (or via
   `deploy-worker.yml` once the runner is registered).
4. **Set up the relay** following `gmail-relay/README.md`: paste `Code.gs`, set
   `WORKER_URL` + `RELAY_SECRET` (= the secret from step 2) in Script Properties,
   add the 1-minute `pollLamp` trigger, and click through the one-time
   unverified-app consent.
5. **Demo:** email `v.lamp.controller@gmail.com` subject `lamp`, body
   `on, warm, 30%`. Within ~90s the lamp turns on at 30% warm.

> No `IMAP_*` and no OAuth tokens are used. Gmail credentials never leave Google.
> Stage 3 has **no sender allowlist** (accepted residual risk); attachment
> validation + allowlist land in Stage 4.
```

- [ ] **Step 3: Add the two secrets to `docs/ops/secrets.md`**

Add rows/entries matching the file's existing format:

```markdown
| `ANTHROPIC_API_KEY` | Cloudflare (`wrangler secret put`) | Claude Haiku 4.5 intent extraction in the Worker | No |
| `RELAY_SHARED_SECRET` | Cloudflare (`wrangler secret put`) + Apps Script `RELAY_SECRET` property | Bearer auth on `POST /ingest` (relay → Worker) | No |
```

(If `secrets.md` uses prose rather than a table, add equivalent prose entries instead.)

- [ ] **Step 4: Commit**

```bash
git add docs/ops/first-time-setup.md docs/ops/secrets.md
git commit -m "docs(ops): Stage 3 setup steps + new secrets"
```

---

### Task 11: Full verification + memory update

**Files:** none (verification only).

- [ ] **Step 1: Run the full worker suite + typecheck**

Run: `cd worker && pnpm typecheck && pnpm test`
Expected: all suites green, including the pre-existing Stage 2 tests (commands, ack, health, kv, auth, schema) plus the new llm, ingest, and ingest_route specs.

- [ ] **Step 2: Dry-run the deploy build**

Run: `cd worker && pnpm deploy:dry`
Expected: `wrangler deploy --dry-run` succeeds (no cron, valid config). This catches wrangler.toml mistakes without deploying.

- [ ] **Step 3: Update the project-state memory**

Edit `/Users/volovely/.claude/projects/-Users-volovely-GitHub-lamp-controller/memory/project_lamp-controller-state.md`: mark Stage 3 delivered, record that ingestion is the Apps Script relay (`gmail-relay/`) → `POST /ingest` (not IMAP/cron), the dedicated mailbox `v.lamp.controller@gmail.com`, no sender allowlist (accepted residual risk, closed in Stage 4), model `claude-haiku-4-5`, and the two new secrets (`ANTHROPIC_API_KEY`, `RELAY_SHARED_SECRET`).

- [ ] **Step 4: Final confirmation**

State plainly which suites passed (with counts from the test output) and that `deploy:dry` succeeded. Do not claim the live email→lamp demo works — that requires the human relay setup + a registered runner (Stage 3 gated-on-setup).
```
