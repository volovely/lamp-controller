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
