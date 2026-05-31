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
