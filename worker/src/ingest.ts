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
  if (await hasSeen(env, msgId)) {
    return json({ status: "duplicate", reply: null });
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
