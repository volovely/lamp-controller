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
    const firstPut = kv.puts[0];
    expect(firstPut).toBeDefined();
    expect(firstPut?.options?.expirationTtl).toBe(86400);
  });
});
