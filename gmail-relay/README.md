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
