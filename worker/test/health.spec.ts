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
