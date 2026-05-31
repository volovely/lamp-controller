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
