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
