import { requireRelayBearer, type RelayAuthEnv } from "./auth";
import { json } from "./http";
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

  // Dedupe before spending an LLM call. Relay mark-read is the primary guard;
  // seen:<msgId> is belt-and-braces for double-delivery or partial failure.
  try {
    if (await hasSeen(env, msgId)) {
      return json({ status: "duplicate", reply: null });
    }
  } catch (err) {
    console.log(JSON.stringify({ level: "error", msg: "hasSeen KV read failed", msgId, err: String(err) }));
    return json({ status: "error", reply: null }, 502);
  }

  let extracted: LlmCommand | null;
  try {
    extracted = await deps.extract(text);
  } catch (err) {
    // Transport / API failure: do NOT mark seen — relay must leave the message
    // unread so it retries on the next tick. Return 5xx to signal transience.
    console.log(JSON.stringify({ level: "error", msg: "ingest extract failed", msgId, err: String(err) }));
    return json({ status: "error", reply: null }, 502);
  }

  if (extracted === null) {
    // On the unparseable path nothing is committed yet. If the seen: write fails,
    // return 5xx so the relay leaves the message unread and retries — we avoid
    // replying + marking read against unrecorded state.
    try {
      await markSeen(env, msgId);
    } catch (err) {
      console.log(JSON.stringify({ level: "error", msg: "markSeen failed on unparseable path", msgId, err: String(err) }));
      return json({ status: "error", reply: null }, 502);
    }
    return json({ status: "unparseable", reply: UNPARSEABLE_REPLY });
  }

  const command: Command = {
    id: deps.uuid(),
    ...extracted,
    created_at: deps.now(),
    source_msg_id: msgId,
  };

  // Step 1 — write the command first. If this fails, return 5xx and leave the
  // message unread so the relay retries cleanly next tick.
  try {
    await putCommand(env, command);
  } catch (err) {
    console.log(JSON.stringify({ level: "error", msg: "putCommand failed", msgId, err: String(err) }));
    return json({ status: "error", reply: null }, 502);
  }

  // Step 2 — best-effort seen: write. The command is already queued; relay
  // mark-read on this 200 is the primary dedupe guard, so a failed seen: write
  // must not fail the request or trigger a retry that would double-queue.
  try {
    await markSeen(env, msgId);
  } catch (err) {
    console.log(JSON.stringify({ level: "warn", msg: "markSeen failed on queued path", msgId, err: String(err) }));
  }
  return json({ status: "queued", command: extracted, reply: null });
}
