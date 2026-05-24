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
