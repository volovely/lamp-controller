# Stage 0 — Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the lamp-controller monorepo on GitHub with skeleton modules, green CI, the self-hosted Mac runner registered, and ops docs in place — so all later stages have a working build/test/deploy substrate.

**Architecture:** Monorepo with two language modules (`worker/` TypeScript + `mac-agent/` Swift Package) sharing a `shared/command-schema.json` contract. CI on free github-hosted runners; deploys on a self-hosted Mac runner labelled `lamp-mac`. Empty-but-real test suites prove the toolchain is wired correctly before any feature code is written.

**Tech Stack:**
- Worker: TypeScript, pnpm, wrangler 3.x, vitest, miniflare
- Mac agent: Swift 5.10+ (swift-testing), Swift Package Manager
- CI: GitHub Actions (Ubuntu + macOS hosted runners)
- Repo: GitHub (visibility set by user)
- Local: macOS 14+

---

## File structure produced by this stage

```
lamp-controller/
├── README.md                              # top-level overview, pointer to docs/
├── CLAUDE.md                              # (already present) commit conventions
├── .gitignore                             # (already present)
├── .editorconfig                          # indent/EOL conventions across langs
│
├── worker/
│   ├── package.json                       # pnpm-managed; vitest + wrangler deps
│   ├── pnpm-lock.yaml                     # committed lockfile
│   ├── tsconfig.json                      # strict TS
│   ├── wrangler.toml                      # name, compatibility_date, scheduled stub
│   ├── src/index.ts                       # exports {scheduled, fetch} no-op stubs
│   └── test/health.spec.ts                # one real passing test
│
├── mac-agent/
│   ├── Package.swift                      # swift-tools 5.10, library + exe targets
│   ├── Sources/LampAgent/Hello.swift      # one trivial function to anchor tests
│   ├── Sources/lamp-agent/main.swift      # prints version + exits
│   ├── Tests/LampAgentTests/HelloTests.swift  # one real passing swift-testing test
│   └── README.md                          # build/test instructions
│
├── homebridge/
│   └── README.md                          # placeholder; filled in Stage 1
│
├── shared/
│   └── command-schema.json                # canonical Command JSON Schema (draft-07)
│
├── docs/
│   ├── superpowers/
│   │   ├── specs/2026-05-24-lamp-controller-design.md   # already committed
│   │   └── plans/2026-05-24-stage-0-foundations.md      # this file
│   ├── ops/
│   │   ├── first-time-setup.md            # self-hosted runner + GitHub repo setup
│   │   ├── runbook.md                     # stub; filled progressively
│   │   └── secrets.md                     # stub; secret-name registry
│   └── architecture.md                    # 1-page overview pointing into the spec
│
└── .github/
    └── workflows/
        └── ci.yml                         # path-filtered worker-ci + mac-agent-ci
```

Each file is small and single-purpose. Larger files (e.g. the spec) already exist and aren't touched here.

---

## Task 1: Create the GitHub repository

**Files:** none yet (working with `gh` CLI + remote `origin`).

- [ ] **Step 1: Verify gh CLI is authenticated**

Run from project root:

```bash
gh auth status
```

Expected: shows logged-in account. If not, the user runs `gh auth login` interactively (this is a human-in-the-loop step — do NOT attempt to log in non-interactively).

- [ ] **Step 2: Confirm visibility with the user**

Ask the user, via `AskUserQuestion`:

> Repository visibility for `volovely/lamp-controller`?
> - Private (recommended — contains personal automation config)
> - Public (open-source friendly, but never check in secrets)

Default is **Private** unless the user picks Public.

- [ ] **Step 3: Create the remote repository**

Run (substitute `--private` or `--public` per Step 2):

```bash
gh repo create volovely/lamp-controller \
  --private \
  --source=. \
  --remote=origin \
  --description "Email-controlled Apple Home lamp via Cloudflare Worker + macOS daemon"
```

Expected: prints `https://github.com/volovely/lamp-controller` and adds the `origin` remote locally.

- [ ] **Step 4: Push existing commits to GitHub**

```bash
git push -u origin main
```

Expected: prints `branch 'main' set up to track 'origin/main'`. No errors.

- [ ] **Step 5: Verify the repository is reachable**

```bash
gh repo view --json url,visibility,defaultBranchRef
```

Expected JSON contains `"defaultBranchRef":{"name":"main"}` and the chosen visibility.

- [ ] **Step 6: Commit (none — push was the act)**

No new local commit. Verification only.

---

## Task 2: Top-level files — README, .editorconfig, architecture overview

**Files:**
- Create: `README.md`
- Create: `.editorconfig`
- Create: `docs/architecture.md`

- [ ] **Step 1: Write README.md**

Contents:

```markdown
# lamp-controller

Email-controlled Apple Home lamp.

Send a Gmail with subject `lamp ...`, an authenticating attachment, and a
natural-language body (`turn on, warm white, 30%`). A Cloudflare Worker reads
the mail, validates the sender, extracts the command via Claude Haiku, and
queues it. A Swift CLI daemon on the home Mac pulls commands and applies them
via Homebridge.

## Repo layout

| Path | Purpose |
|---|---|
| `worker/` | Cloudflare Worker (TypeScript) — cron + fetch handlers |
| `mac-agent/` | Swift CLI daemon running on the home Mac |
| `homebridge/` | Reference Homebridge config + setup notes |
| `shared/` | Cross-module contracts (JSON schemas) |
| `docs/` | Specs, plans, ops runbook |
| `.github/workflows/` | CI + deploy pipelines |

## Status

See [the design spec](docs/superpowers/specs/2026-05-24-lamp-controller-design.md)
and the [stage plans](docs/superpowers/plans/) for the staged build plan.

## Local development

Each module has its own README:
- [`worker/README.md`](worker/README.md) — Worker setup, tests, deploy
- [`mac-agent/README.md`](mac-agent/README.md) — Swift build, test, install

Operational setup (one-time, on the home Mac) lives in
[`docs/ops/first-time-setup.md`](docs/ops/first-time-setup.md).
```

- [ ] **Step 2: Write .editorconfig**

Contents:

```
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
trim_trailing_whitespace = true
indent_style = space
indent_size = 2

[*.swift]
indent_size = 4

[Makefile]
indent_style = tab
```

- [ ] **Step 3: Write docs/architecture.md**

Contents:

```markdown
# Architecture overview

This is a one-page summary. The authoritative document is the design spec at
[`docs/superpowers/specs/2026-05-24-lamp-controller-design.md`](superpowers/specs/2026-05-24-lamp-controller-design.md).

## Data flow

```
email → Gmail → Cloudflare Worker (cron) → Workers KV → Mac daemon (poll)
                                                              ↓
                                                    Homebridge → lamp
```

## Components

- **Worker** (`worker/`) — Cloudflare Worker. `scheduled` handler reads Gmail
  every minute, validates, calls Claude Haiku for intent, writes commands to
  KV. `fetch` handler serves pending commands to the Mac.
- **Mac agent** (`mac-agent/`) — Swift CLI daemon. Short-polls the Worker
  every 12 s, executes commands via Homebridge's local REST API, acks back.
- **Homebridge** — off-the-shelf install on the Mac, the bridge to HomeKit.

## Trust boundaries

1. Anyone → Gmail: validated by attachment check + From-allowlist in the Worker.
2. Worker → Mac: bearer token shared via `wrangler secret` and `config.toml`.
3. Mac → Homebridge: localhost-only, bearer-authenticated.

## Build & deploy

CI runs on github-hosted runners. Deploys (`worker/` and `mac-agent/`) run
on a self-hosted Mac runner. See
[`docs/ops/first-time-setup.md`](ops/first-time-setup.md).
```

- [ ] **Step 4: Verify files render correctly**

```bash
ls -la README.md .editorconfig docs/architecture.md
```

Expected: all three files listed, non-zero sizes.

- [ ] **Step 5: Commit**

```bash
git add README.md .editorconfig docs/architecture.md
git commit -m "docs: add top-level README, editorconfig, and architecture overview"
git push
```

---

## Task 3: Scaffold mac-agent Swift Package — failing test first

**Files:**
- Create: `mac-agent/Package.swift`
- Create: `mac-agent/Sources/LampAgent/Hello.swift`
- Create: `mac-agent/Sources/lamp-agent/main.swift`
- Create: `mac-agent/Tests/LampAgentTests/HelloTests.swift`
- Create: `mac-agent/README.md`

We start with TDD: a real failing test, a real passing implementation. This proves the SwiftPM + swift-testing toolchain works before any feature code is added.

- [ ] **Step 1: Create the Swift Package manifest**

Contents of `mac-agent/Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LampAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LampAgent", targets: ["LampAgent"]),
        .executable(name: "lamp-agent", targets: ["lamp-agent"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "LampAgent"),
        .executableTarget(name: "lamp-agent", dependencies: ["LampAgent"]),
        .testTarget(name: "LampAgentTests", dependencies: ["LampAgent"]),
    ]
)
```

Note: Stage 0 has no external dependencies. The `pfw-*` libraries (Dependencies, IssueReporting, etc.) get added in Stage 1 when we actually need them.

- [ ] **Step 2: Write the failing test**

Contents of `mac-agent/Tests/LampAgentTests/HelloTests.swift`:

```swift
import Testing
@testable import LampAgent

@Suite("Hello")
struct HelloTests {
    @Test("greet returns the configured greeting")
    func greet() {
        let result = Hello.greet(name: "lamp")
        #expect(result == "hello, lamp")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd mac-agent && swift test 2>&1 | tail -20
```

Expected: build error `cannot find 'Hello' in scope` (or similar). The test target compiles, the library target fails to find the symbol.

- [ ] **Step 4: Write the minimal implementation**

Contents of `mac-agent/Sources/LampAgent/Hello.swift`:

```swift
public enum Hello {
    public static func greet(name: String) -> String {
        "hello, \(name)"
    }
}
```

- [ ] **Step 5: Write the executable main**

Contents of `mac-agent/Sources/lamp-agent/main.swift`:

```swift
import LampAgent

print(Hello.greet(name: "world"))
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd mac-agent && swift test 2>&1 | tail -10
```

Expected: `Test run with X tests passed`. Zero failures.

- [ ] **Step 7: Run the executable as a smoke test**

```bash
cd mac-agent && swift run lamp-agent
```

Expected: prints `hello, world` and exits 0.

- [ ] **Step 8: Write mac-agent/README.md**

Contents:

```markdown
# mac-agent

Swift CLI daemon that runs on the home Mac. Pulls commands from the
Cloudflare Worker and applies them to the lamp via Homebridge's local REST API.

## Build

```bash
swift build
```

## Test

```bash
swift test
```

## Run (smoke test only at Stage 0)

```bash
swift run lamp-agent
```

Prints a greeting and exits. Real daemon behavior is added in Stage 1.

## Install (Stage 1+)

Installation as a launchd LaunchAgent is documented in
[`scripts/install.sh`](scripts/install.sh) and the ops runbook.
```

- [ ] **Step 9: Commit**

```bash
git add mac-agent/
git commit -m "feat(mac-agent): scaffold Swift Package with passing skeleton test"
git push
```

---

## Task 4: Scaffold worker TypeScript project — failing test first

**Files:**
- Create: `worker/package.json`
- Create: `worker/tsconfig.json`
- Create: `worker/wrangler.toml`
- Create: `worker/src/index.ts`
- Create: `worker/test/health.spec.ts`
- Create: `worker/README.md`
- Create: `worker/.gitignore`

- [ ] **Step 1: Create worker/.gitignore**

Contents of `worker/.gitignore`:

```
node_modules/
.wrangler/
dist/
coverage/
*.local
```

(Root `.gitignore` also covers most of these; this duplicates locally so `cd worker && git status` is clean.)

- [ ] **Step 2: Create package.json**

Contents of `worker/package.json`:

```json
{
  "name": "lamp-controller-worker",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "scripts": {
    "typecheck": "tsc --noEmit",
    "test": "vitest run",
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "deploy:dry": "wrangler deploy --dry-run"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^4.20240605.0",
    "typescript": "^5.5.3",
    "vitest": "^1.6.0",
    "wrangler": "^3.62.0"
  }
}
```

- [ ] **Step 3: Create tsconfig.json**

Contents of `worker/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "types": ["@cloudflare/workers-types"]
  },
  "include": ["src/**/*", "test/**/*"]
}
```

- [ ] **Step 4: Create wrangler.toml (scheduled stub)**

Contents of `worker/wrangler.toml`:

```toml
name = "lamp-controller"
main = "src/index.ts"
compatibility_date = "2026-05-01"
compatibility_flags = ["nodejs_compat"]

# Cron is wired up here so the schema validates; the handler is a no-op
# until Stage 3 actually fetches Gmail.
[triggers]
crons = ["* * * * *"]
```

KV namespace bindings and secrets are intentionally omitted; they appear in Stage 2.

- [ ] **Step 5: Install dependencies and commit the lockfile**

```bash
cd worker && pnpm install
```

Expected: creates `node_modules/` (gitignored) and `pnpm-lock.yaml`. No errors.

If `pnpm` isn't installed:

```bash
npm i -g pnpm
```

- [ ] **Step 6: Write the failing test**

Contents of `worker/test/health.spec.ts`:

```ts
import { describe, expect, it } from "vitest";
import worker from "../src/index";

describe("fetch handler", () => {
  it("responds to GET /health with ok:true", async () => {
    const req = new Request("https://example.com/health");
    const res = await worker.fetch(req);

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual({ ok: true });
  });

  it("responds 404 to unknown paths", async () => {
    const req = new Request("https://example.com/nope");
    const res = await worker.fetch(req);

    expect(res.status).toBe(404);
  });
});
```

- [ ] **Step 7: Run the test to verify it fails**

```bash
cd worker && pnpm test 2>&1 | tail -20
```

Expected: failure mentioning that `../src/index` cannot be found, or the default export is missing.

- [ ] **Step 8: Write minimal implementation**

Contents of `worker/src/index.ts`:

```ts
export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    return new Response("not found", { status: 404 });
  },

  async scheduled(): Promise<void> {
    // No-op at Stage 0. Stage 3 fills this in with Gmail + LLM.
  },
};
```

- [ ] **Step 9: Run the test to verify it passes**

```bash
cd worker && pnpm test 2>&1 | tail -10
```

Expected: `Test Files 1 passed`, `Tests 2 passed`. Zero failures.

- [ ] **Step 10: Run typecheck to validate the source**

```bash
cd worker && pnpm typecheck
```

Expected: exits 0 with no output. If it errors on `Request` / `Response` not being found, ensure `@cloudflare/workers-types` is in `types: [...]` in `tsconfig.json`. The `pnpm deploy:dry` script is kept in `package.json` for local use after Cloudflare credentials are configured (Stage 2), but is not run in Stage 0.

- [ ] **Step 11: Write worker/README.md**

Contents:

```markdown
# worker

Cloudflare Worker. Exports a `fetch` handler (serves pending commands to the
Mac) and a `scheduled` handler (reads Gmail, queues commands).

## Setup

```bash
pnpm install
```

## Test

```bash
pnpm test           # vitest
pnpm typecheck      # tsc --noEmit
pnpm deploy:dry     # wrangler deploy --dry-run
```

## Deploy

Done via GitHub Actions on push to `main` (see `.github/workflows/deploy-worker.yml`,
added in Stage 2). Local manual deploy:

```bash
pnpm deploy
```

Requires `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` env vars.

## Layout

| File | Purpose |
|---|---|
| `src/index.ts` | Worker entrypoint: `fetch` + `scheduled` |
| `wrangler.toml` | Worker config: name, cron, bindings |
| `test/*.spec.ts` | Vitest unit tests |
```

- [ ] **Step 12: Commit**

```bash
cd /Users/volovely/GitHub/lamp-controller
git add worker/
git commit -m "feat(worker): scaffold Cloudflare Worker with health endpoint and tests"
git push
```

---

## Task 5: Shared schema, homebridge placeholder, ops doc stubs

**Files:**
- Create: `shared/command-schema.json`
- Create: `homebridge/README.md`
- Create: `docs/ops/runbook.md`
- Create: `docs/ops/secrets.md`

The schema is the *contract* between Worker and Mac. Defining it now means both sides develop against the same source of truth from day one.

- [ ] **Step 1: Write shared/command-schema.json**

Contents:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "https://github.com/volovely/lamp-controller/shared/command-schema.json",
  "title": "Command",
  "description": "A single lamp command emitted by the Worker and consumed by the Mac agent.",
  "type": "object",
  "required": ["id", "action", "created_at", "source_msg_id"],
  "additionalProperties": false,
  "properties": {
    "id": {
      "type": "string",
      "format": "uuid",
      "description": "UUIDv4 generated by the Worker."
    },
    "action": {
      "type": "string",
      "enum": ["on", "off", "set"],
      "description": "on/off toggle power; set adjusts brightness/color without toggling."
    },
    "brightness": {
      "type": "integer",
      "minimum": 0,
      "maximum": 100,
      "description": "Lamp brightness percent. Meaningful for 'on' and 'set'."
    },
    "color": {
      "type": "object",
      "required": ["hex"],
      "additionalProperties": false,
      "properties": {
        "hex": {
          "type": "string",
          "pattern": "^#[0-9a-fA-F]{6}$"
        }
      }
    },
    "duration_minutes": {
      "type": "integer",
      "minimum": 1,
      "maximum": 1440,
      "description": "Reserved for future scheduling feature. Ignored in v1."
    },
    "created_at": {
      "type": "string",
      "format": "date-time"
    },
    "source_msg_id": {
      "type": "string",
      "description": "Gmail message ID; for audit and idempotency."
    }
  }
}
```

- [ ] **Step 2: Write homebridge/README.md (Stage 1 placeholder)**

Contents:

```markdown
# Homebridge integration

Homebridge installation and configuration is done as a one-time manual step
on the home Mac. The Mac agent (`mac-agent/`) talks to Homebridge's local
REST API to control the lamp.

This README is a stub. The full setup steps — install, lamp pairing, plugin
selection, REST API token generation — are filled in during Stage 1 by the
`homebridge-integrator` sub-agent. See the design spec
([`../docs/superpowers/specs/2026-05-24-lamp-controller-design.md`](../docs/superpowers/specs/2026-05-24-lamp-controller-design.md))
for the contract the Mac agent uses.

## Files in this directory (post-Stage 1)

| File | Purpose |
|---|---|
| `config.json.example` | Reference Homebridge config (sanitized) |
| `README.md` | This file — setup walkthrough |
```

- [ ] **Step 3: Write docs/ops/runbook.md (stub)**

Contents:

```markdown
# Operational runbook

What to do when things break. Populated progressively across stages.

## Known incidents and responses

_None yet — populated during Stage 5._

## Common checks

- **Is the Worker alive?** `curl https://lamp-controller.<account>.workers.dev/health`
- **Is the Mac agent running?** `launchctl list | grep com.lamp.agent`
- **Is the self-hosted runner online?** Repo Settings → Actions → Runners.

## Log locations

| Component | Location |
|---|---|
| Worker | `wrangler tail` (live) or Cloudflare dashboard |
| Mac agent | `~/Library/Logs/lamp-agent.log` |
| Homebridge | `~/.homebridge/homebridge.log` |
```

- [ ] **Step 4: Write docs/ops/secrets.md**

Contents:

```markdown
# Secrets registry

A canonical list of every secret in the system, where it lives, who provisions
it, and how to rotate.

| Secret | Where | Provisioned by | Used by | Rotation |
|---|---|---|---|---|
| `IMAP_USER` | `wrangler secret` (Cloudflare) | user, one-time | Worker `gmail.ts` | rare |
| `IMAP_APP_PASSWORD` | `wrangler secret` | user, via Google App Passwords UI | Worker `gmail.ts` | revoke + regenerate when needed |
| `ANTHROPIC_API_KEY` | `wrangler secret` | user, via console.anthropic.com | Worker `llm.ts` | rotate yearly |
| `VALIDATION_API_KEY` | `wrangler secret` | user, from 3rd-party validator | Worker `validation.ts` | per provider policy |
| `MAC_SHARED_SECRET` | `wrangler secret` + `~/.config/lamp-agent/config.toml` on Mac | user generates with `openssl rand -hex 32`; sets identical value in both places | Worker `auth.ts`, Mac `WorkerClient.swift` | rotate together |
| `ALLOWED_SENDERS` | `wrangler secret` (comma-separated) | user | Worker `gmail.ts` | as needed |
| `homebridge_token` | `~/.config/lamp-agent/config.toml` on Mac | Homebridge UI generates | Mac `HomebridgeClient.swift` | regenerate via Homebridge UI |
| `CLOUDFLARE_API_TOKEN` | GitHub repo secret | user, scoped token from Cloudflare dashboard | `deploy-worker.yml` | rotate yearly |
| `CLOUDFLARE_ACCOUNT_ID` | GitHub repo secret | user | `deploy-worker.yml` | n/a (not secret in practice) |

## Provisioning commands (reference)

```bash
# Worker secrets — run from worker/ directory
wrangler secret put IMAP_USER
wrangler secret put IMAP_APP_PASSWORD
wrangler secret put ANTHROPIC_API_KEY
wrangler secret put MAC_SHARED_SECRET
wrangler secret put VALIDATION_API_KEY
wrangler secret put ALLOWED_SENDERS

# GitHub repo secrets
gh secret set CLOUDFLARE_API_TOKEN
gh secret set CLOUDFLARE_ACCOUNT_ID
```

## Never commit

- `*.local`, `config.toml` (committed: `config.toml.example` only)
- `.env*`
- `secrets/`
- Anything with the suffix `.key` or `.pem`
```

- [ ] **Step 5: Verify all files exist**

```bash
ls -la shared/command-schema.json homebridge/README.md docs/ops/
```

Expected: all four files listed, non-zero sizes.

- [ ] **Step 6: Validate the JSON schema is well-formed**

```bash
python3 -c "import json; json.load(open('shared/command-schema.json'))"
```

Expected: silent success (no output, exit 0). If it errors, fix the JSON.

- [ ] **Step 7: Commit**

```bash
git add shared/ homebridge/ docs/ops/
git commit -m "feat: define shared command schema and ops doc stubs"
git push
```

---

## Task 6: GitHub Actions CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

CI runs on every PR (and pushes to non-main branches), using free github-hosted runners. Two parallel jobs, each path-filtered so unrelated changes are skipped.

- [ ] **Step 1: Write the CI workflow**

Contents of `.github/workflows/ci.yml`:

```yaml
name: ci

on:
  pull_request:
    branches: [main]
  push:
    branches-ignore: [main]

# Cancel in-progress runs for the same ref when a new commit lands.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      worker: ${{ steps.filter.outputs.worker }}
      mac-agent: ${{ steps.filter.outputs.mac-agent }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            worker:
              - 'worker/**'
              - '.github/workflows/ci.yml'
            mac-agent:
              - 'mac-agent/**'
              - '.github/workflows/ci.yml'

  worker-ci:
    needs: changes
    if: needs.changes.outputs.worker == 'true'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: worker
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
        with:
          version: 9
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: pnpm
          cache-dependency-path: worker/pnpm-lock.yaml
      - run: pnpm install --frozen-lockfile
      - run: pnpm typecheck
      - run: pnpm test

  mac-agent-ci:
    needs: changes
    if: needs.changes.outputs.mac-agent == 'true'
    runs-on: macos-14
    defaults:
      run:
        working-directory: mac-agent
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - run: swift --version
      - run: swift build
      - run: swift test
```

Key choices explained:
- **`paths-filter` job + downstream `if:`** — the standard pattern for conditional path-filtered jobs without breaking required-status-checks.
- **`pull_request` + `push` excluding main** — avoids running CI twice on a merged PR (deploy workflows handle main).
- **`macos-14`** — pinned, has Xcode 15+ with Swift 5.10 and `swift-testing`.
- **`pnpm install --frozen-lockfile`** — fails CI if `pnpm-lock.yaml` is stale.

- [ ] **Step 2: Validate the workflow locally with yamllint**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"
```

Expected: silent success. If you get an indentation error, fix it.

- [ ] **Step 3: Commit and push (this triggers CI on a feature branch)**

```bash
git checkout -b chore/initial-ci
git add .github/
git commit -m "ci: add path-filtered worker and mac-agent jobs"
git push -u origin chore/initial-ci
```

- [ ] **Step 4: Open a PR and watch CI**

```bash
gh pr create --base main --head chore/initial-ci \
  --title "ci: initial pipeline" \
  --body "Path-filtered worker + mac-agent CI jobs. First run validates the toolchain."
```

- [ ] **Step 5: Verify both jobs go green**

```bash
gh pr checks --watch
```

Expected: `worker-ci` and `mac-agent-ci` both report `pass`. The `changes` job always runs and passes.

If a job fails:
- Read the failure log via `gh run view --log-failed`.
- Fix the underlying issue (likely a missing file, stale lockfile, or Xcode version mismatch).
- Push the fix; CI re-runs automatically.

- [ ] **Step 6: Merge the PR**

```bash
gh pr merge chore/initial-ci --squash --delete-branch
git checkout main && git pull --ff-only
```

---

## Task 7: Document self-hosted Mac runner setup

**Files:**
- Create: `docs/ops/first-time-setup.md`

This document is the *only* place that describes a manual setup step — registering the self-hosted runner — and it has to be precise enough that the user can follow it without further help.

- [ ] **Step 1: Write docs/ops/first-time-setup.md**

Contents:

```markdown
# First-time setup

Manual, one-time steps to bring a new clone of this repo to a working state.
Re-run any section if the underlying credential is rotated or the host is
rebuilt.

## 1. Local prerequisites (home Mac)

```bash
# Xcode command-line tools (Swift)
xcode-select --install

# Homebrew (if not already)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# pnpm (worker development)
brew install pnpm

# wrangler (Worker deploys)
brew install cloudflare-wrangler2

# gh CLI (already required to create the repo)
brew install gh
```

Verify:

```bash
swift --version            # >= 5.10
pnpm --version             # >= 9
wrangler --version         # >= 3.62
gh --version               # >= 2.40
```

## 2. Cloudflare account (Worker deploys)

1. Sign up at https://dash.cloudflare.com (free plan is enough).
2. From the dashboard, copy your **Account ID** (sidebar of the Workers & Pages section).
3. Create a scoped API token: **My Profile → API Tokens → Create Token →
   Custom Token** with the following permissions:
   - **Account → Workers Scripts → Edit**
   - **Account → Workers KV Storage → Edit**
   - Account resource: the account from step 2.

   Copy the token; it's shown once.

4. Provision both as GitHub repository secrets:

   ```bash
   gh secret set CLOUDFLARE_API_TOKEN
   gh secret set CLOUDFLARE_ACCOUNT_ID
   ```

   Paste each value when prompted.

## 3. Register the self-hosted GitHub Actions runner (home Mac)

This runner executes deploy workflows. It does **not** run CI (CI uses
free github-hosted runners).

1. In the repo: **Settings → Actions → Runners → New self-hosted runner**.
   Select **macOS** and the **arm64/x64** matching your Mac.

2. Follow the on-screen download + configure commands; the registration
   step looks like:

   ```bash
   mkdir ~/actions-runner && cd ~/actions-runner
   curl -o actions-runner-osx.tar.gz -L https://github.com/actions/runner/releases/download/v2.319.1/actions-runner-osx-arm64-2.319.1.tar.gz
   tar xzf actions-runner-osx.tar.gz
   ./config.sh --url https://github.com/volovely/lamp-controller \
               --token <REGISTRATION_TOKEN_FROM_GITHUB> \
               --name lamp-mac \
               --labels self-hosted,macOS,lamp-mac \
               --work _work \
               --unattended
   ```

   The exact registration token and download URL are shown by GitHub on the
   page — use those, not these.

3. Install the runner as a launchd service so it survives logout/reboot:

   ```bash
   cd ~/actions-runner
   ./svc.sh install
   ./svc.sh start
   ./svc.sh status
   ```

   Expected last line: `actions.runner.volovely-lamp-controller.lamp-mac (running)`.

4. Confirm the runner appears as **Idle** in **Settings → Actions → Runners**.

5. Sanity check — manually trigger a deploy workflow:

   Once `deploy-worker.yml` exists (Stage 2), trigger it with:

   ```bash
   gh workflow run deploy-worker.yml
   gh run watch
   ```

   It should pick up the `lamp-mac` runner.

## 4. Gmail (Stage 3)

Not yet needed at Stage 0. When Stage 3 lands:

1. Enable 2-Step Verification on the Gmail account.
2. Generate an App Password (16-char): https://myaccount.google.com/apppasswords
3. `cd worker && wrangler secret put IMAP_APP_PASSWORD`.

## 5. Anthropic API key (Stage 3)

Not yet needed at Stage 0. When Stage 3 lands:

1. Sign in at https://console.anthropic.com.
2. Create an API key.
3. `cd worker && wrangler secret put ANTHROPIC_API_KEY`.

## 6. Homebridge (Stage 1)

Not yet needed at Stage 0. Setup is captured in
[`homebridge/README.md`](../../homebridge/README.md) during Stage 1.
```

- [ ] **Step 2: Verify markdown links resolve**

```bash
grep -oE '\[.*?\]\(.*?\)' docs/ops/first-time-setup.md | head
```

Inspect a few — make sure relative paths point to files that actually exist.

- [ ] **Step 3: Commit**

```bash
git add docs/ops/first-time-setup.md
git commit -m "docs(ops): document first-time setup for runner, Cloudflare, secrets"
git push
```

---

## Task 8: Final verification — green CI on `main`, runner online

**Files:** none modified.

- [ ] **Step 1: Check main is green**

```bash
gh run list --branch main --limit 5
```

Expected: most recent runs show `completed success` for any CI/deploy workflows triggered on main.

Note: With path-filtered CI, a push to main might not trigger CI directly (CI runs on PRs and non-main pushes). That's fine — the green state is established by the merged PR run.

- [ ] **Step 2: Verify the self-hosted runner is Idle**

```bash
gh api repos/volovely/lamp-controller/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Expected:

```json
{
  "name": "lamp-mac",
  "status": "online",
  "labels": ["self-hosted", "macOS", "lamp-mac"]
}
```

If the runner is `offline`, restart it on the Mac:

```bash
cd ~/actions-runner && ./svc.sh stop && ./svc.sh start
```

- [ ] **Step 3: Verify the skeleton actually builds and tests**

From the project root:

```bash
(cd worker && pnpm install --frozen-lockfile && pnpm test && pnpm typecheck)
(cd mac-agent && swift build && swift test)
```

Expected: both pipelines pass with zero failures.

- [ ] **Step 4: Take a final snapshot for the Stage 1 brief**

```bash
git log --oneline
```

Expected: a clean linear history showing the design spec, CLAUDE.md, README/architecture, mac-agent scaffold, worker scaffold, shared schema + ops stubs, CI, first-time-setup — roughly 7-8 commits, no fixup commits, no Claude attribution.

- [ ] **Step 5: Tag the stage completion**

```bash
git tag -a stage-0-foundations -m "Stage 0 complete: monorepo scaffold, green CI, runner online"
git push origin stage-0-foundations
```

Tagging gives Stage 1 a clean "this is what you build on" marker.

---

## Definition of done

Stage 0 is complete when **all** of the following are true:

- [ ] `volovely/lamp-controller` exists on GitHub with chosen visibility.
- [ ] `git log` shows the design spec, CLAUDE.md, and ~6 Stage 0 commits on `main`.
- [ ] `worker/` types check, tests pass (`pnpm test` shows ≥2 passing).
- [ ] `mac-agent/` builds, tests pass (`swift test` shows ≥1 passing).
- [ ] `shared/command-schema.json` is valid JSON Schema draft-07.
- [ ] `docs/ops/first-time-setup.md`, `docs/ops/secrets.md`, `docs/ops/runbook.md` all exist with substantive content (no TODO stubs in the prose).
- [ ] `.github/workflows/ci.yml` runs both jobs on PRs; the most recent PR shows both green.
- [ ] The `lamp-mac` self-hosted runner shows `online`/`Idle` in repo settings.
- [ ] `stage-0-foundations` tag exists on `origin`.

Once all boxes check, Stage 1 (Mac → lamp) is ready to plan.
