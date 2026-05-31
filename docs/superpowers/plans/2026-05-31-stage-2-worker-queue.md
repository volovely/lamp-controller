# Stage 2 — Worker queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the lamp command queue from a Cloudflare Worker backed by Workers KV — `GET /commands` / `POST /ack` / `GET /health` with bearer auth — and add a `WorkerCommandSource` so the Mac agent polls the cloud instead of a local file.

**Architecture:** The Worker is a single `fetch` router over one KV namespace (`COMMANDS`); commands live at `command:<uuid>`, are listed/validated on `GET /commands`, and deleted on `POST /ack`. The Mac agent gains a `CommandSource.worker(...)` backend that plugs into the existing Stage 1 seam — `PollLoop`'s dedup/stale/backoff are unchanged; the only new behaviour is that `ack` now deletes server-side.

**Tech Stack:** Worker — TypeScript, Zod, vitest, wrangler 3.x, Workers KV. Mac — Swift 6, swift-testing, URLProtocol stubs, TOMLKit. CI — existing `worker-ci` / `mac-agent-ci`; deploy on the self-hosted `lamp-mac` runner.

**Reference spec:** [`docs/superpowers/specs/2026-05-31-stage-2-worker-queue-design.md`](../specs/2026-05-31-stage-2-worker-queue-design.md). Always pass this path to sub-agents.

---

## Toolchain notes (read first)

- **Worker:** run from `worker/` with `pnpm`. `pnpm install` first (the lockfile + `pnpm-workspace.yaml` with `allowBuilds` already exist from Stage 0). Tests: `pnpm test` (vitest). Typecheck: `pnpm typecheck`.
- **Mac:** swift-testing's macOS module ships with Xcode — every `swift` command needs `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The package is at `mac-agent/` (swift-tools 6.0).
- The shared contract is `shared/command-schema.json` (fields: `id`, `action` ∈ {on,off,set}, `brightness?` 0–100, `color_temp_k?` 2700–6500, `duration_minutes?`, `created_at`, `source_msg_id`; required: `id`, `action`, `created_at`, `source_msg_id`). The Worker's Zod schema and the Mac's `Command` model both mirror it. **Do not reintroduce the old `color`/`hex` field.**

---

## File structure produced by this stage

```
worker/
├── package.json                      # + zod dependency
├── wrangler.toml                     # + [[kv_namespaces]] COMMANDS binding
├── src/
│   ├── index.ts                      # router: /commands, /ack, /health, 404 (replaces Stage 0 stub)
│   ├── auth.ts                        # requireBearer(request, env)
│   ├── schema.ts                     # Zod Command schema + parse helper
│   └── kv.ts                         # listCommands(env), deleteCommands(env, ids)
└── test/
    ├── health.spec.ts                # existing (kept; import path unchanged)
    ├── auth.spec.ts                  # 401 paths
    ├── commands.spec.ts              # GET /commands list + validate + drop-malformed
    └── ack.spec.ts                   # POST /ack deletes; 400 on bad body

mac-agent/
├── Sources/LampAgent/
│   ├── WorkerCommandSource.swift     # CommandSource.worker(baseURL:sharedSecret:session:)
│   ├── Config.swift                  # + command_source / worker_url / shared_secret / state_path
│   └── Dependencies+Live.swift       # Runtime.makePollLoop builds source by config
├── Sources/lamp-agent/main.swift     # (unchanged — wiring stays in Runtime)
├── Resources/config.toml.example     # + worker source keys
└── Tests/LampAgentTests/
    ├── WorkerCommandSourceTests.swift
    └── ConfigTests.swift             # + worker/file cases

.github/workflows/deploy-worker.yml   # dormant self-hosted deploy
docs/ops/first-time-setup.md          # + Stage 2 Cloudflare/KV/secret section
```

---

## Task 1: Worker — Zod Command schema

**Agent:** lamp-worker. **Files:**
- Modify: `worker/package.json`
- Create: `worker/src/schema.ts`
- Create: `worker/test/schema.spec.ts`

- [ ] **Step 1: Add zod to package.json**

Edit `worker/package.json` to add a `dependencies` block (it currently only has `devDependencies`). Insert before `"devDependencies"`:

```json
  "dependencies": {
    "zod": "^3.23.8"
  },
```

- [ ] **Step 2: Install**

```bash
cd worker && pnpm install 2>&1 | tail -5
```

Expected: zod resolved, no errors.

- [ ] **Step 3: Write the failing test**

Create `worker/test/schema.spec.ts`:

```ts
import { describe, expect, it } from "vitest";
import { parseCommand } from "../src/schema";

describe("parseCommand", () => {
  it("accepts a full valid command", () => {
    const c = parseCommand({
      id: "11111111-1111-1111-1111-111111111111",
      action: "on",
      brightness: 30,
      color_temp_k: 2700,
      created_at: "2026-05-31T10:00:00Z",
      source_msg_id: "manual",
    });
    expect(c?.action).toBe("on");
    expect(c?.color_temp_k).toBe(2700);
  });

  it("accepts a minimal off command", () => {
    const c = parseCommand({
      id: "a",
      action: "off",
      created_at: "2026-05-31T10:00:00Z",
      source_msg_id: "m",
    });
    expect(c?.action).toBe("off");
    expect(c?.brightness).toBeUndefined();
  });

  it("returns null for an unknown action", () => {
    expect(
      parseCommand({ id: "a", action: "dim", created_at: "x", source_msg_id: "m" })
    ).toBeNull();
  });

  it("returns null when a required field is missing", () => {
    expect(parseCommand({ action: "on" })).toBeNull();
  });

  it("returns null for out-of-range brightness", () => {
    expect(
      parseCommand({ id: "a", action: "on", brightness: 150, created_at: "x", source_msg_id: "m" })
    ).toBeNull();
  });

  it("returns null for non-object input", () => {
    expect(parseCommand("nope")).toBeNull();
    expect(parseCommand(null)).toBeNull();
  });
});
```

- [ ] **Step 4: Run it — expect failure**

```bash
cd worker && pnpm test schema 2>&1 | tail -15
```

Expected: fails — cannot find `../src/schema`.

- [ ] **Step 5: Implement the schema**

Create `worker/src/schema.ts`:

```ts
import { z } from "zod";

// Mirrors shared/command-schema.json
export const CommandSchema = z.object({
  id: z.string(),
  action: z.enum(["on", "off", "set"]),
  brightness: z.number().int().min(0).max(100).optional(),
  color_temp_k: z.number().int().min(2700).max(6500).optional(),
  duration_minutes: z.number().int().min(1).max(1440).optional(),
  created_at: z.string(),
  source_msg_id: z.string(),
});

export type Command = z.infer<typeof CommandSchema>;

/** Returns the parsed Command, or null if the value does not conform. */
export function parseCommand(value: unknown): Command | null {
  const result = CommandSchema.safeParse(value);
  return result.success ? result.data : null;
}
```

- [ ] **Step 6: Run it — expect pass**

```bash
cd worker && pnpm test schema 2>&1 | tail -10
```

Expected: all 6 tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add worker/package.json worker/pnpm-lock.yaml worker/src/schema.ts worker/test/schema.spec.ts
git commit -m "feat(worker): add Zod Command schema mirroring the shared contract"
```

---

## Task 2: Worker — bearer auth

**Agent:** lamp-worker. **Files:**
- Create: `worker/src/auth.ts`
- Create: `worker/test/auth.spec.ts`

- [ ] **Step 1: Write the failing test**

Create `worker/test/auth.spec.ts`:

```ts
import { describe, expect, it } from "vitest";
import { requireBearer } from "../src/auth";

const env = { MAC_SHARED_SECRET: "s3cret" } as const;

describe("requireBearer", () => {
  it("returns null when the token matches", () => {
    const req = new Request("https://x/commands", {
      headers: { Authorization: "Bearer s3cret" },
    });
    expect(requireBearer(req, env)).toBeNull();
  });

  it("returns 401 when the header is missing", () => {
    const req = new Request("https://x/commands");
    const res = requireBearer(req, env);
    expect(res?.status).toBe(401);
  });

  it("returns 401 when the token is wrong", () => {
    const req = new Request("https://x/commands", {
      headers: { Authorization: "Bearer nope" },
    });
    expect(requireBearer(req, env)?.status).toBe(401);
  });

  it("returns 401 when the scheme is not Bearer", () => {
    const req = new Request("https://x/commands", {
      headers: { Authorization: "Basic s3cret" },
    });
    expect(requireBearer(req, env)?.status).toBe(401);
  });
});
```

- [ ] **Step 2: Run it — expect failure**

```bash
cd worker && pnpm test auth 2>&1 | tail -15
```

Expected: cannot find `../src/auth`.

- [ ] **Step 3: Implement auth**

Create `worker/src/auth.ts`:

```ts
export interface AuthEnv {
  MAC_SHARED_SECRET: string;
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

/**
 * Returns a 401 Response if the request lacks a valid bearer token,
 * or null if the caller is authorized.
 */
export function requireBearer(request: Request, env: AuthEnv): Response | null {
  const header = request.headers.get("Authorization") ?? "";
  const prefix = "Bearer ";
  const ok =
    header.startsWith(prefix) &&
    timingSafeEqual(header.slice(prefix.length), env.MAC_SHARED_SECRET);
  if (ok) return null;
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "content-type": "application/json" },
  });
}
```

- [ ] **Step 4: Run it — expect pass**

```bash
cd worker && pnpm test auth 2>&1 | tail -10
```

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add worker/src/auth.ts worker/test/auth.spec.ts
git commit -m "feat(worker): add bearer auth with constant-time compare"
```

---

## Task 3: Worker — KV access layer

**Agent:** lamp-worker. **Files:**
- Create: `worker/src/kv.ts`
- Create: `worker/test/kv.spec.ts`

The KV layer lists/parses/deletes `command:<uuid>` keys. Tests use an in-memory fake implementing the small subset of `KVNamespace` we call (`list`, `get`, `delete`).

- [ ] **Step 1: Write the failing test**

Create `worker/test/kv.spec.ts`:

```ts
import { describe, expect, it } from "vitest";
import { listCommands, deleteCommands } from "../src/kv";

// Minimal in-memory KV fake covering list/get/delete.
function fakeKV(initial: Record<string, string> = {}) {
  const store = new Map(Object.entries(initial));
  return {
    store,
    async list({ prefix }: { prefix: string }) {
      const keys = [...store.keys()]
        .filter((k) => k.startsWith(prefix))
        .map((name) => ({ name }));
      return { keys, list_complete: true, cursor: "" };
    },
    async get(key: string) {
      return store.get(key) ?? null;
    },
    async delete(key: string) {
      store.delete(key);
    },
  };
}

describe("listCommands", () => {
  it("returns parsed commands for valid entries", async () => {
    const kv = fakeKV({
      "command:a": JSON.stringify({
        id: "a", action: "on", brightness: 30, color_temp_k: 2700,
        created_at: "2026-05-31T10:00:00Z", source_msg_id: "m",
      }),
    });
    const cmds = await listCommands({ COMMANDS: kv } as any);
    expect(cmds).toHaveLength(1);
    expect(cmds[0]!.id).toBe("a");
  });

  it("skips malformed and non-conforming entries", async () => {
    const kv = fakeKV({
      "command:good": JSON.stringify({
        id: "good", action: "off",
        created_at: "2026-05-31T10:00:00Z", source_msg_id: "m",
      }),
      "command:badjson": "{ not json",
      "command:badshape": JSON.stringify({ action: "dim" }),
    });
    const cmds = await listCommands({ COMMANDS: kv } as any);
    expect(cmds.map((c) => c.id)).toEqual(["good"]);
  });

  it("ignores keys outside the command: prefix", async () => {
    const kv = fakeKV({
      "seen:x": "1",
      "command:a": JSON.stringify({
        id: "a", action: "off",
        created_at: "2026-05-31T10:00:00Z", source_msg_id: "m",
      }),
    });
    const cmds = await listCommands({ COMMANDS: kv } as any);
    expect(cmds).toHaveLength(1);
  });
});

describe("deleteCommands", () => {
  it("deletes command:<id> for each id", async () => {
    const kv = fakeKV({
      "command:a": "{}",
      "command:b": "{}",
      "command:c": "{}",
    });
    await deleteCommands({ COMMANDS: kv } as any, ["a", "b"]);
    expect([...kv.store.keys()]).toEqual(["command:c"]);
  });
});
```

- [ ] **Step 2: Run it — expect failure**

```bash
cd worker && pnpm test kv 2>&1 | tail -15
```

Expected: cannot find `../src/kv`.

- [ ] **Step 3: Implement the KV layer**

Create `worker/src/kv.ts`:

```ts
import { parseCommand, type Command } from "./schema";

export interface KVEnv {
  COMMANDS: KVNamespace;
}

const PREFIX = "command:";

/** Lists all queued commands, skipping malformed / non-conforming entries. */
export async function listCommands(env: KVEnv): Promise<Command[]> {
  const out: Command[] = [];
  const { keys } = await env.COMMANDS.list({ prefix: PREFIX });
  for (const { name } of keys) {
    const raw = await env.COMMANDS.get(name);
    if (raw === null) continue;
    let value: unknown;
    try {
      value = JSON.parse(raw);
    } catch {
      console.log(`skip malformed KV value at ${name}`);
      continue;
    }
    const command = parseCommand(value);
    if (command === null) {
      console.log(`skip non-conforming command at ${name}`);
      continue;
    }
    out.push(command);
  }
  return out;
}

/** Deletes command:<id> for each id. */
export async function deleteCommands(env: KVEnv, ids: string[]): Promise<void> {
  await Promise.all(ids.map((id) => env.COMMANDS.delete(`${PREFIX}${id}`)));
}
```

- [ ] **Step 4: Run it — expect pass**

```bash
cd worker && pnpm test kv 2>&1 | tail -10
```

Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add worker/src/kv.ts worker/test/kv.spec.ts
git commit -m "feat(worker): add KV command list/delete with validation"
```

---

## Task 4: Worker — router (fetch handler)

**Agent:** lamp-worker. **Files:**
- Modify: `worker/src/index.ts`
- Create: `worker/test/commands.spec.ts`
- Create: `worker/test/ack.spec.ts`
- Modify: `worker/test/health.spec.ts` (pass an `env` arg)

The router wires auth + KV into `GET /commands`, `POST /ack`, `GET /health`, else 404. Tests pass a fake `env` (the same in-memory KV fake) directly to `worker.fetch(req, env)`.

- [ ] **Step 1: Write the commands route test**

Create `worker/test/commands.spec.ts`:

```ts
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
```

- [ ] **Step 2: Write the ack route test**

Create `worker/test/ack.spec.ts`:

```ts
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
```

- [ ] **Step 3: Update the health test to pass env**

Replace `worker/test/health.spec.ts` with:

```ts
import { describe, expect, it } from "vitest";
import worker from "../src/index";

const env = { MAC_SHARED_SECRET: "s3cret", COMMANDS: {} } as any;

describe("fetch handler", () => {
  it("responds to GET /health with ok:true", async () => {
    const res = await worker.fetch(new Request("https://example.com/health"), env);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });

  it("responds 404 to unknown paths", async () => {
    const res = await worker.fetch(new Request("https://example.com/nope"), env);
    expect(res.status).toBe(404);
  });
});
```

- [ ] **Step 4: Run the route tests — expect failure**

```bash
cd worker && pnpm test 2>&1 | tail -20
```

Expected: `commands` / `ack` fail (router not implemented; `fetch` ignores `env`).

- [ ] **Step 5: Implement the router**

Replace `worker/src/index.ts`:

```ts
import { requireBearer } from "./auth";
import { listCommands, deleteCommands } from "./kv";

export interface Env {
  MAC_SHARED_SECRET: string;
  COMMANDS: KVNamespace;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ ok: true });
    }

    if (request.method === "GET" && url.pathname === "/commands") {
      const unauthorized = requireBearer(request, env);
      if (unauthorized) return unauthorized;
      const commands = await listCommands(env);
      return json({ commands });
    }

    if (request.method === "POST" && url.pathname === "/ack") {
      const unauthorized = requireBearer(request, env);
      if (unauthorized) return unauthorized;
      let body: unknown;
      try {
        body = await request.json();
      } catch {
        return json({ error: "invalid json" }, 400);
      }
      const ids = (body as { ids?: unknown })?.ids;
      if (!Array.isArray(ids) || !ids.every((x) => typeof x === "string")) {
        return json({ error: "ids must be an array of strings" }, 400);
      }
      await deleteCommands(env, ids);
      return new Response(null, { status: 204 });
    }

    return new Response("not found", { status: 404 });
  },

  async scheduled(): Promise<void> {
    // No-op until Stage 3 (Gmail + LLM).
  },
};
```

- [ ] **Step 6: Run the full suite + typecheck — expect pass**

```bash
cd worker && pnpm test 2>&1 | tail -12 && pnpm typecheck 2>&1 | tail -5
```

Expected: all suites pass; `tsc --noEmit` exits 0.

- [ ] **Step 7: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add worker/src/index.ts worker/test/commands.spec.ts worker/test/ack.spec.ts worker/test/health.spec.ts
git commit -m "feat(worker): route /commands, /ack, /health with bearer auth + KV"
```

---

## Task 5: Worker — KV namespace binding in wrangler.toml

**Agent:** lamp-ops. **Files:**
- Modify: `worker/wrangler.toml`

The binding makes `env.COMMANDS` available at runtime. The namespace `id` is created by the user (documented in Task 9); use a clearly-marked placeholder so `wrangler deploy --dry-run` parses and the engineer knows to fill it.

- [ ] **Step 1: Add the KV namespace binding**

Append to `worker/wrangler.toml`:

```toml

# Workers KV: command queue. Create with:
#   wrangler kv namespace create COMMANDS
# then paste the returned id below (and a preview_id for `wrangler dev`).
[[kv_namespaces]]
binding = "COMMANDS"
id = "REPLACE_WITH_KV_NAMESPACE_ID"
```

- [ ] **Step 2: Validate the toml parses**

```bash
cd /Users/volovely/GitHub/lamp-controller
python3 -c "import tomllib; tomllib.load(open('worker/wrangler.toml','rb')); print('toml ok')"
```

Expected: `toml ok`. (If `tomllib` is unavailable on the runner's Python, instead run `cd worker && npx wrangler deploy --dry-run --outdir /tmp/wo 2>&1 | tail -5` and confirm it parses config — it will fail later on the placeholder id, which is fine for this step; the goal is config syntax.)

- [ ] **Step 3: Commit**

```bash
git add worker/wrangler.toml
git commit -m "feat(worker): bind COMMANDS KV namespace"
```

---

## Task 6: Mac — WorkerCommandSource

**Agent:** lamp-mac. **REQUIRED SKILLS:** pfw-dependencies, pfw-testing. **Files:**
- Create: `mac-agent/Sources/LampAgent/WorkerCommandSource.swift`
- Create: `mac-agent/Tests/LampAgentTests/WorkerCommandSourceTests.swift`

`CommandSource.worker(...)` mirrors the existing `CommandSource.file(...)` factory and the `URLProtocol`-stub test style from `LampClientHomebridgeTests.swift`. `pending()` GETs `/commands`; `ack(_:)` POSTs `/ack`. Both send `Authorization: Bearer <sharedSecret>` and verify the response host matches the configured host.

- [ ] **Step 1: Write the failing test**

Create `mac-agent/Tests/LampAgentTests/WorkerCommandSourceTests.swift`:

```swift
import Foundation
import Testing
@testable import LampAgent

@Suite("WorkerCommandSource", .serialized)
struct WorkerCommandSourceTests {
    // MARK: Stub URLProtocol (one handler at a time; suite is .serialized)
    private final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data))?
        override class func canInit(with request: URLRequest) -> Bool { handler != nil }
        override class func canonicalRequest(for r: URLRequest) -> URLRequest { r }
        override func startLoading() {
            var bodyData: Data? = request.httpBody
            if bodyData == nil, let s = request.httpBodyStream {
                var d = Data(); s.open(); var buf = [UInt8](repeating: 0, count: 4096)
                while s.hasBytesAvailable { let n = s.read(&buf, maxLength: 4096); if n > 0 { d.append(contentsOf: buf[..<n]) } }
                s.close(); bodyData = d
            }
            do {
                let (resp, data) = try Self.handler!(request, bodyData)
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
        override func stopLoading() {}
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        return URLSession(configuration: c)
    }()

    private let baseURL = URL(string: "https://lamp.example.workers.dev")!

    private func source() -> CommandSource {
        .worker(baseURL: baseURL, sharedSecret: "s3cret", session: Self.session)
    }

    private func ok(_ url: URL, _ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test("pending GETs /commands with bearer and decodes the array")
    func pendingDecodes() async throws {
        final class Box: @unchecked Sendable { var req: URLRequest? }
        let box = Box()
        Stub.handler = { req, _ in
            box.req = req
            let body = """
            {"commands":[{"id":"a","action":"on","brightness":30,"color_temp_k":2700,"created_at":"2026-05-31T10:00:00Z","source_msg_id":"m"}]}
            """.data(using: .utf8)!
            return (self.ok(req.url!), body)
        }
        defer { Stub.handler = nil }

        let cmds = try await source().pending()

        #expect(cmds.count == 1)
        #expect(cmds.first?.id == "a")
        #expect(cmds.first?.colorTempK == 2700)
        #expect(box.req?.url?.path == "/commands")
        #expect(box.req?.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
    }

    @Test("pending skips a malformed element")
    func pendingLossy() async throws {
        Stub.handler = { req, _ in
            let body = """
            {"commands":[{"id":"a","action":"off","created_at":"2026-05-31T10:00:00Z","source_msg_id":"m"},{"id":"b","action":"explode","created_at":"2026-05-31T10:00:00Z","source_msg_id":"m"}]}
            """.data(using: .utf8)!
            return (self.ok(req.url!), body)
        }
        defer { Stub.handler = nil }
        let cmds = try await source().pending()
        #expect(cmds.map(\.id) == ["a"])
    }

    @Test("pending throws on non-2xx")
    func pendingThrows() async {
        Stub.handler = { req, _ in (self.ok(req.url!, 500), Data()) }
        defer { Stub.handler = nil }
        await #expect(throws: (any Error).self) { try await self.source().pending() }
    }

    @Test("ack POSTs ids with bearer and accepts 204")
    func ackPosts() async throws {
        final class Box: @unchecked Sendable { var req: URLRequest?; var body: Data? }
        let box = Box()
        Stub.handler = { req, body in
            box.req = req; box.body = body
            return (self.ok(req.url!, 204), Data())
        }
        defer { Stub.handler = nil }

        try await source().ack(["a", "b"])

        #expect(box.req?.httpMethod == "POST")
        #expect(box.req?.url?.path == "/ack")
        #expect(box.req?.value(forHTTPHeaderField: "Authorization") == "Bearer s3cret")
        let parsed = try JSONSerialization.jsonObject(with: box.body ?? Data()) as? [String: Any]
        #expect((parsed?["ids"] as? [String]) == ["a", "b"])
    }

    @Test("ack throws on non-2xx")
    func ackThrows() async {
        Stub.handler = { req, _ in (self.ok(req.url!, 401), Data()) }
        defer { Stub.handler = nil }
        await #expect(throws: (any Error).self) { try await self.source().ack(["a"]) }
    }
}
```

- [ ] **Step 2: Run it — expect failure**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd mac-agent && swift test --filter WorkerCommandSourceTests 2>&1 | tail -15
```

Expected: `type 'CommandSource' has no member 'worker'`.

- [ ] **Step 3: Implement WorkerCommandSource**

Create `mac-agent/Sources/LampAgent/WorkerCommandSource.swift`:

```swift
import Foundation

extension CommandSource {
    public enum WorkerError: Error, Equatable {
        case requestFailed(status: Int)
        case unreachable
        case hostMismatch
    }

    /// Worker-backed source. `pending` GETs /commands; `ack` POSTs /ack.
    /// Both send `Authorization: Bearer <sharedSecret>` and verify the response
    /// host matches `baseURL` (anti-redirect/spoof guard).
    public static func worker(
        baseURL: URL,
        sharedSecret: String,
        session: URLSession = .shared
    ) -> CommandSource {
        let expectedHost = baseURL.host

        @Sendable func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let data: Data, response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw WorkerError.unreachable
            }
            guard let http = response as? HTTPURLResponse else {
                throw WorkerError.requestFailed(status: -1)
            }
            if let expectedHost, http.url?.host != expectedHost {
                throw WorkerError.hostMismatch
            }
            guard (200...299).contains(http.statusCode) else {
                throw WorkerError.requestFailed(status: http.statusCode)
            }
            return (data, http)
        }

        struct CommandsResponse: Decodable { let commands: [Failable<Command>] }

        return CommandSource(
            pending: {
                var request = URLRequest(url: baseURL.appendingPathComponent("commands"))
                request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")
                let (data, _) = try await send(request)
                let decoded = try Command.jsonDecoder.decode(CommandsResponse.self, from: data)
                return decoded.commands.compactMap(\.value)
            },
            ack: { ids in
                var request = URLRequest(url: baseURL.appendingPathComponent("ack"))
                request.httpMethod = "POST"
                request.setValue("Bearer \(sharedSecret)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["ids": ids])
                _ = try await send(request)
            }
        )
    }
}

/// Decodes to `nil` instead of throwing when an element is malformed.
/// (Mirrors the helper in FileCommandSource; kept file-private here.)
private struct Failable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try? container.decode(Wrapped.self)
    }
}
```

Note: `FileCommandSource.swift` already declares a `private struct Failable`. Because both are `private` (file-scoped), the duplicate name does not collide across files — this compiles. Do not make either `public`/`internal`.

- [ ] **Step 4: Run it — expect pass**

```bash
swift test --filter WorkerCommandSourceTests 2>&1 | tail -10
```

Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-agent/Sources/LampAgent/WorkerCommandSource.swift mac-agent/Tests/LampAgentTests/WorkerCommandSourceTests.swift
git commit -m "feat(mac-agent): add Worker-backed CommandSource"
```

---

## Task 7: Mac — Config (command_source) + Runtime wiring

**Agent:** lamp-mac. **REQUIRED SKILL:** pfw-testing. **Files:**
- Modify: `mac-agent/Sources/LampAgent/Config.swift`
- Modify: `mac-agent/Sources/LampAgent/Dependencies+Live.swift`
- Modify: `mac-agent/Tests/LampAgentTests/ConfigTests.swift`

Add `command_source` (default `worker`), `worker_url`, `shared_secret`, and a `state_path` for `acked.json` (needed because the worker source has no `commands_path`). `Runtime.makePollLoop` selects the source.

- [ ] **Step 1: Write the failing Config tests**

Add these tests to `mac-agent/Tests/LampAgentTests/ConfigTests.swift` inside the existing `@Suite("Config")` struct. (Existing tests set `lamp_backend`/homekit fields; reuse that pattern. The minimal valid config for these new tests uses the file backend for the lamp so we isolate command-source parsing.)

```swift
    @Test("command_source defaults to worker and requires worker_url + shared_secret")
    func commandSourceDefaultsWorker() throws {
        let toml = """
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        worker_url = "https://lamp.example.workers.dev"
        shared_secret = "s3cret"
        """
        let config = try Config.parse(toml)
        #expect(config.commandSource == .worker)
        #expect(config.workerURL == URL(string: "https://lamp.example.workers.dev")!)
        #expect(config.sharedSecret == "s3cret")
    }

    @Test("worker command source without worker_url throws")
    func workerMissingURL() {
        let toml = """
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        shared_secret = "s3cret"
        """
        #expect(throws: Config.ConfigError.self) { try Config.parse(toml) }
    }

    @Test("file command source requires commands_path")
    func fileSourceParses() throws {
        let toml = """
        command_source = "file"
        commands_path = "/tmp/commands.json"
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        """
        let config = try Config.parse(toml)
        #expect(config.commandSource == .file)
        #expect(config.commandsPath == "/tmp/commands.json")
    }

    @Test("state_path defaults under the home dir and expands ~")
    func statePathDefaultAndTilde() throws {
        let toml = """
        poll_interval_s = 12
        lamp_backend = "shortcuts"
        worker_url = "https://lamp.example.workers.dev"
        shared_secret = "s3cret"
        state_path = "~/x/acked.json"
        """
        let config = try Config.parse(toml)
        #expect(!config.statePath.hasPrefix("~"))
        #expect(config.statePath.hasSuffix("/x/acked.json"))
    }
```

Also: the existing tests likely require `commands_path`. Since `commands_path` is now only required for the **file** source, the new default-worker tests above omit it. If an existing test breaks because `commands_path` became optional, that's expected — update it in Step 3.

- [ ] **Step 2: Run it — expect failure**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd mac-agent && swift test --filter ConfigTests 2>&1 | tail -20
```

Expected: compile failure — `Config` has no `commandSource` / `workerURL` / `sharedSecret` / `statePath`.

- [ ] **Step 3: Update Config.swift**

In `mac-agent/Sources/LampAgent/Config.swift`:

(a) Add the enum and fields. After the `Backend` enum add:

```swift
    public enum CommandSourceKind: String, Sendable, Equatable {
        case worker
        case file
    }
```

(b) Change `commandsPath` to optional and add the new stored properties. Replace the property block:

```swift
    public var commandsPath: String?
    public var statePath: String
    public var pollIntervalSeconds: Int
    public var commandSource: CommandSourceKind
    public var workerURL: URL?
    public var sharedSecret: String?
    public var lampBackend: Backend
    public var shortcutPrefix: String
    public var homebridgeURL: URL?
    public var homebridgeToken: String?
    public var accessoryId: String?
    public var homekitHelperPath: String?
    public var homekitAccessoryName: String?
```

(c) Replace the `init` signature/body to include the new fields (defaults: `commandSource: .worker`, `commandsPath: nil`, `statePath` has no default — always set by parse; `workerURL: nil`, `sharedSecret: nil`):

```swift
    public init(
        commandsPath: String? = nil,
        statePath: String,
        pollIntervalSeconds: Int,
        commandSource: CommandSourceKind = .worker,
        workerURL: URL? = nil,
        sharedSecret: String? = nil,
        lampBackend: Backend = .homekit,
        shortcutPrefix: String = "Lamp",
        homebridgeURL: URL? = nil,
        homebridgeToken: String? = nil,
        accessoryId: String? = nil,
        homekitHelperPath: String? = nil,
        homekitAccessoryName: String? = nil
    ) {
        self.commandsPath = commandsPath
        self.statePath = statePath
        self.pollIntervalSeconds = pollIntervalSeconds
        self.commandSource = commandSource
        self.workerURL = workerURL
        self.sharedSecret = sharedSecret
        self.lampBackend = lampBackend
        self.shortcutPrefix = shortcutPrefix
        self.homebridgeURL = homebridgeURL
        self.homebridgeToken = homebridgeToken
        self.accessoryId = accessoryId
        self.homekitHelperPath = homekitHelperPath
        self.homekitAccessoryName = homekitAccessoryName
    }
```

(d) In `parse`, replace the `commands_path` + `poll_interval_s` reads (the lines `let rawPath = try requireString("commands_path") ... let pollInterval = try requireInt("poll_interval_s")`) with:

```swift
        let pollInterval = try requireInt("poll_interval_s")

        // command_source — optional, defaults to .worker
        let commandSource: CommandSourceKind
        if let raw = optionalString("command_source") {
            guard let parsed = CommandSourceKind(rawValue: raw) else {
                throw ConfigError.invalidBackend(raw)
            }
            commandSource = parsed
        } else {
            commandSource = .worker
        }

        // commands_path — required only for the file source
        let commandsPath = optionalString("commands_path").map { ($0 as NSString).expandingTildeInPath }
        if commandSource == .file, commandsPath == nil {
            throw ConfigError.missingKey("commands_path")
        }

        // worker_url + shared_secret — required only for the worker source
        let workerURLString = optionalString("worker_url")
        let workerURL: URL?
        if let workerURLString {
            guard let url = URL(string: workerURLString) else {
                throw ConfigError.invalidURL(workerURLString)
            }
            workerURL = url
        } else {
            workerURL = nil
        }
        let sharedSecret = optionalString("shared_secret")
        if commandSource == .worker {
            if workerURL == nil { throw ConfigError.missingKey("worker_url") }
            if sharedSecret == nil { throw ConfigError.missingKey("shared_secret") }
        }

        // state_path — where acked.json lives; defaults under ~/.local/state
        let statePath = (optionalString("state_path")
            ?? "~/.local/state/lamp-agent/acked.json")
        let expandedStatePath = (statePath as NSString).expandingTildeInPath
```

(e) Remove the now-deleted `let path = ...` usage. Update the final `return Config(...)` to pass the new fields:

```swift
        return Config(
            commandsPath: commandsPath,
            statePath: expandedStatePath,
            pollIntervalSeconds: pollInterval,
            commandSource: commandSource,
            workerURL: workerURL,
            sharedSecret: sharedSecret,
            lampBackend: backend,
            shortcutPrefix: prefix,
            homebridgeURL: homebridgeURL,
            homebridgeToken: homebridgeToken,
            accessoryId: accessoryId,
            homekitHelperPath: homekitHelperPath,
            homekitAccessoryName: homekitAccessoryName
        )
```

- [ ] **Step 4: Update Runtime.makePollLoop**

In `mac-agent/Sources/LampAgent/Dependencies+Live.swift`, replace `makePollLoop` and `ackedURL`:

```swift
    public static func makePollLoop(config: Config) -> PollLoop {
        let source: CommandSource
        switch config.commandSource {
        case .worker:
            // parse() guarantees these are present for the worker source.
            source = .worker(
                baseURL: config.workerURL!,
                sharedSecret: config.sharedSecret!
            )
        case .file:
            source = .file(at: URL(fileURLWithPath: config.commandsPath!))
        }
        return PollLoop(
            source: source,
            executor: .live(),
            ackStore: .file(at: URL(fileURLWithPath: config.statePath))
        )
    }
```

(Delete the old `ackedURL(forCommandsAt:)` helper — `statePath` replaces it.)

- [ ] **Step 5: Fix any existing ConfigTests that assumed required commands_path**

Run the suite; if an existing test (e.g. a "missing required key" test that dropped `commands_path`) now behaves differently, update it so its intent holds under the new rules (e.g. assert that omitting `poll_interval_s` throws, since that is still required). Show the change in the commit.

```bash
swift test --filter ConfigTests 2>&1 | tail -20
```

- [ ] **Step 6: Run the full suite — expect pass**

```bash
swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5
```

Expected: build succeeds; all suites pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-agent/Sources/LampAgent/Config.swift mac-agent/Sources/LampAgent/Dependencies+Live.swift mac-agent/Tests/LampAgentTests/ConfigTests.swift
git commit -m "feat(mac-agent): select command source in config (default Worker)"
```

---

## Task 8: Mac — config.toml.example + README

**Agent:** lamp-mac. **Files:**
- Modify: `mac-agent/Resources/config.toml.example`
- Modify: `mac-agent/README.md`

- [ ] **Step 1: Update config.toml.example**

Read `mac-agent/Resources/config.toml.example`, then add a command-source section near the top (after the `# Copy to ...` header, before the lamp-backend section):

```toml
# --- Command source: where the agent pulls commands from ---
command_source  = "worker"          # "worker" (default) | "file"

# worker source (Stage 2+): poll the Cloudflare Worker
worker_url      = "https://lamp-controller.<subdomain>.workers.dev"
shared_secret   = "REPLACE_WITH_MAC_SHARED_SECRET"   # identical to the Worker's secret

# applied-command ledger (dedup); defaults to ~/.local/state/lamp-agent/acked.json
# state_path    = "~/.local/state/lamp-agent/acked.json"

# file source (Stage 1, offline testing): read a local JSON array instead
# command_source = "file"
# commands_path  = "~/.local/state/lamp-agent/commands.json"
```

Keep the existing lamp-backend (`lamp_backend`/`homekit_*`/etc.) and `poll_interval_s` sections.

- [ ] **Step 2: Update README "Command source" section**

In `mac-agent/README.md`, add a short `## Command source` section explaining the `worker` (default) vs `file` backends, that `worker_url` + `shared_secret` are required for worker and `commands_path` for file, and that `shared_secret` must equal the Worker's `MAC_SHARED_SECRET`. Reference `docs/superpowers/specs/2026-05-31-stage-2-worker-queue-design.md`.

- [ ] **Step 3: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add mac-agent/Resources/config.toml.example mac-agent/README.md
git commit -m "docs(mac-agent): document worker command source config"
```

---

## Task 9: deploy-worker.yml + ops docs

**Agent:** lamp-ops. **Files:**
- Create: `.github/workflows/deploy-worker.yml`
- Modify: `docs/ops/first-time-setup.md`

- [ ] **Step 1: Write the deploy workflow**

Create `.github/workflows/deploy-worker.yml`:

```yaml
name: deploy-worker

on:
  push:
    branches: [main]
    paths:
      - 'worker/**'
      - '.github/workflows/deploy-worker.yml'

concurrency:
  group: deploy-worker
  cancel-in-progress: false

jobs:
  deploy:
    runs-on: [self-hosted, macOS, lamp-mac]
    defaults:
      run:
        working-directory: worker
    env:
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          version: 11
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: pnpm
          cache-dependency-path: worker/pnpm-lock.yaml
      - run: pnpm install --frozen-lockfile
      - run: pnpm test
      - run: pnpm exec wrangler deploy
```

Note: runs only on the self-hosted `lamp-mac` runner (per the design). Until that runner is registered, pushes touching `worker/**` queue a `deploy` job that waits — expected and harmless. Node 22 / pnpm 11 match the `ci.yml` settings fixed in Stage 0.

- [ ] **Step 2: Lint the workflow**

```bash
cd /Users/volovely/GitHub/lamp-controller
python3 -c "t=open('.github/workflows/deploy-worker.yml').read(); assert '\t' not in t; assert 'self-hosted' in t and 'lamp-mac' in t; assert 'wrangler deploy' in t; print('workflow ok')"
```

Expected: `workflow ok`.

- [ ] **Step 3: Add a Stage 2 section to first-time-setup.md**

Read `docs/ops/first-time-setup.md`, then add a `## Stage 2 — Worker queue` section documenting (concrete commands):

```markdown
## Stage 2 — Worker queue (Cloudflare)

One-time setup to bring the Worker online.

1. **Create the KV namespace** (from `worker/`):
   ```bash
   cd worker
   pnpm exec wrangler kv namespace create COMMANDS
   ```
   Paste the printed `id` into `worker/wrangler.toml` under `[[kv_namespaces]]`
   (replacing `REPLACE_WITH_KV_NAMESPACE_ID`).

2. **Generate the shared secret and set it on the Worker:**
   ```bash
   openssl rand -hex 32            # copy this value
   pnpm exec wrangler secret put MAC_SHARED_SECRET   # paste it
   ```
   Put the **same** value in the Mac's `~/.config/lamp-agent/config.toml` as
   `shared_secret`.

3. **GitHub repo secrets** (for the dormant deploy workflow):
   ```bash
   gh secret set CLOUDFLARE_API_TOKEN     # scoped token: Workers Scripts + KV edit
   gh secret set CLOUDFLARE_ACCOUNT_ID
   ```

4. **First deploy** (manual until the self-hosted runner is registered):
   ```bash
   cd worker && pnpm exec wrangler deploy
   ```
   Note the printed `*.workers.dev` URL → set it as `worker_url` in the Mac config.

5. **Smoke test:**
   ```bash
   curl -s https://lamp-controller.<subdomain>.workers.dev/health   # {"ok":true}
   ```
```

- [ ] **Step 4: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add .github/workflows/deploy-worker.yml docs/ops/first-time-setup.md
git commit -m "ci(worker): add dormant deploy workflow + Stage 2 setup docs"
```

---

## Task 10: Stage review (diff)

**Agent:** lamp-reviewer. **Files:** none (review only).

- [ ] **Step 1: Run both suites**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd /Users/volovely/GitHub/lamp-controller/worker && pnpm test && pnpm typecheck
cd /Users/volovely/GitHub/lamp-controller/mac-agent && swift build && swift test 2>&1 | tail -8
```

Expected: worker suite green + tsc clean; mac suite green.

- [ ] **Step 2: Review the branch diff against the spec**

```bash
cd /Users/volovely/GitHub/lamp-controller
git diff main...stage-2-worker-queue --stat
```

Have lamp-reviewer read the full diff and check: contract consistency (`color_temp_k` across Zod schema ↔ Swift `Command` ↔ `/commands` JSON), bearer auth on `/commands` + `/ack` only (not `/health`), ack=delete semantics, the worker source's host-pinning + lossy decode + error→retry behaviour, `Config` validation per source, no secrets committed, commit messages follow `CLAUDE.md`. Record findings; fix blocking issues with a follow-up commit before Task 11.

---

## Task 11: Integration verification

**Agent:** lamp-integration-verifier. **Files:** none (verification only).

Live `wrangler kv put → lamp` requires the deployed Worker + configured Mac (human setup). Step 1 needs no cloud.

- [ ] **Step 1: Offline contract check (no cloud)**

Confirm the Worker serves the exact contract the Mac decodes, using `wrangler dev` locally + a seeded KV:

```bash
cd /Users/volovely/GitHub/lamp-controller/worker
# Start a local dev server with a temporary local KV, seed one command, curl /commands.
# (wrangler dev --local supports --kv or a [[kv_namespaces]] preview; if seeding local
#  KV is awkward, instead assert the shape via the vitest suite, which already covers it.)
pnpm test 2>&1 | tail -5
```

Expected: the worker suite (which asserts `{commands:[…]}` with `color_temp_k`) passes — this is the contract the Mac's `WorkerCommandSourceTests` decodes. Cross-check that the JSON keys match between `commands.spec.ts` and `WorkerCommandSourceTests.swift`.

- [ ] **Step 2: Live demo (requires deployed Worker + configured Mac)**

Mark BLOCKED-on-setup unless the Worker is deployed and the Mac config has `command_source = "worker"`, `worker_url`, `shared_secret`. When ready:

```bash
SUB=<your-workers-dev-subdomain>
UUID=$(uuidgen)
cd worker && pnpm exec wrangler kv key put --binding=COMMANDS "command:$UUID" \
  "{\"id\":\"$UUID\",\"action\":\"on\",\"brightness\":30,\"color_temp_k\":2700,\"created_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"source_msg_id\":\"manual\"}"
# Within ~12s the running agent (or `swift run lamp-agent --once`) turns the lamp on warm 30%.
```

Expected: lamp obeys; a follow-up `wrangler kv key list --binding=COMMANDS` shows the key deleted (acked). Record evidence.

- [ ] **Step 3: Write the verification report**

Short pass/blocked report: Step 1 result + evidence; Step 2 status (blocked-on-setup or live evidence).

---

## Task 12: Finish the development branch

**Agent:** orchestrator. **REQUIRED SUB-SKILL:** superpowers:finishing-a-development-branch.

- [ ] **Step 1: Confirm clean + green**

```bash
cd /Users/volovely/GitHub/lamp-controller && git status --short
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
(cd worker && pnpm test) && (cd mac-agent && swift test 2>&1 | tail -5)
```

- [ ] **Step 2: Run finishing-a-development-branch**

Push branch + open PR; let CI run (`worker-ci` + `mac-agent-ci` are path-filtered — both run since both trees changed); squash-merge.

- [ ] **Step 3: VERIFY THE SQUASH (lesson from PR #3)**

After the squash-merge, before deleting anything, confirm `main` actually contains every file:

```bash
git checkout main && git pull --ff-only
git diff <branch-tip-sha> HEAD -- worker mac-agent .github docs | wc -l   # expect 0
for f in worker/src/index.ts worker/src/auth.ts worker/src/kv.ts worker/src/schema.ts \
         mac-agent/Sources/LampAgent/WorkerCommandSource.swift; do
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 && echo "OK $f" || echo "MISSING $f"
done
```

If anything is MISSING or the diff is non-zero, recover from the branch tip before proceeding.

- [ ] **Step 4: Note the open deploy gate**

Remind the user that `deploy-worker.yml` and the live `wrangler kv put` demo remain gated on registering the self-hosted `lamp-mac` runner and the one-time Cloudflare setup (`docs/ops/first-time-setup.md` Stage 2).

---

## Definition of done

- [ ] `worker/` exposes `GET /commands` (bearer), `POST /ack` (bearer, deletes), `GET /health` (open), 404 else; `pnpm test` + `pnpm typecheck` green.
- [ ] Worker validates KV values with Zod and drops malformed entries (no 500).
- [ ] `wrangler.toml` binds the `COMMANDS` KV namespace.
- [ ] `mac-agent` has `CommandSource.worker(...)` with bearer auth, host-pinning, lossy decode, and error→throw; `swift test` green.
- [ ] `Config` selects `command_source` (default `worker`), validates `worker_url`+`shared_secret` (worker) / `commands_path` (file), and resolves `state_path` for `acked.json`.
- [ ] `.github/workflows/deploy-worker.yml` targets `[self-hosted, macOS, lamp-mac]`.
- [ ] `docs/ops/first-time-setup.md` documents KV creation, secret distribution, repo secrets, first deploy.
- [ ] Branch merged to `main` via PR with `worker-ci` + `mac-agent-ci` green, **squash contents verified**.

**Gated on human setup (tracked, not blocking the merge):** Cloudflare KV/secret provisioning, first `wrangler deploy`, self-hosted runner registration, and the live `wrangler kv put → lamp` demo.
