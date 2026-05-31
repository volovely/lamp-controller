import { describe, expect, it } from "vitest";
import { requireBearer } from "../src/auth";

const env = { MAC_SHARED_SECRET: "s3cret" } as const;

describe("requireBearer", () => {
  it("returns null when the token matches", () => {
    const req = new Request("https://x/commands", {
      headers: { Authorization: "Bearer s3cret" },
    });
    expect(requireBearer(req, env)).toBeNull();
  });

  it("returns 401 when the header is missing", () => {
    const req = new Request("https://x/commands");
    const res = requireBearer(req, env);
    expect(res?.status).toBe(401);
  });

  it("returns 401 when the token is wrong", () => {
    const req = new Request("https://x/commands", {
      headers: { Authorization: "Bearer nope" },
    });
    expect(requireBearer(req, env)?.status).toBe(401);
  });

  it("returns 401 when the scheme is not Bearer", () => {
    const req = new Request("https://x/commands", {
      headers: { Authorization: "Basic s3cret" },
    });
    expect(requireBearer(req, env)?.status).toBe(401);
  });
});

describe("requireBearer — misconfigured secret", () => {
  const emptyEnv = { MAC_SHARED_SECRET: "" } as const;

  it("returns 500 (not null) when secret is empty and client sends empty token", () => {
    const req = new Request("https://x/commands", {
      headers: { Authorization: "Bearer " },
    });
    const res = requireBearer(req, emptyEnv);
    expect(res).not.toBeNull();
    expect(res?.status).toBe(500);
  });

  it("returns 500 when secret is empty and client sends a valid-looking token", () => {
    const req = new Request("https://x/commands", {
      headers: { Authorization: "Bearer s3cret" },
    });
    const res = requireBearer(req, emptyEnv);
    expect(res).not.toBeNull();
    expect(res?.status).toBe(500);
  });
});
