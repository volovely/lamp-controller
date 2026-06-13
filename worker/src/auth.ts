import { json } from "./http";

export interface AuthEnv {
  MAC_SHARED_SECRET: string;
}

export interface RelayAuthEnv {
  RELAY_SHARED_SECRET: string;
}

/** Constant-time string compare (avoids timing leaks on the token). */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let mismatch = 0;
  for (let i = 0; i < a.length; i++) {
    mismatch |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return mismatch === 0;
}

/**
 * Shared bearer check. Returns a 500 Response if the secret is unconfigured,
 * a 401 Response if the request lacks a valid token, or null if authorized.
 */
function bearerGuard(request: Request, secret: string): Response | null {
  if (!secret) return json({ error: "server misconfigured" }, 500);
  const header = request.headers.get("Authorization") ?? "";
  const prefix = "Bearer ";
  const ok =
    header.startsWith(prefix) && timingSafeEqual(header.slice(prefix.length), secret);
  return ok ? null : json({ error: "unauthorized" }, 401);
}

export function requireBearer(request: Request, env: AuthEnv): Response | null {
  return bearerGuard(request, env.MAC_SHARED_SECRET);
}

export function requireRelayBearer(request: Request, env: RelayAuthEnv): Response | null {
  return bearerGuard(request, env.RELAY_SHARED_SECRET);
}
