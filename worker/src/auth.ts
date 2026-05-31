export interface AuthEnv {
  MAC_SHARED_SECRET: string;
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
 * Returns a 401 Response if the request lacks a valid bearer token,
 * or null if the caller is authorized.
 */
export function requireBearer(request: Request, env: AuthEnv): Response | null {
  const header = request.headers.get("Authorization") ?? "";
  const prefix = "Bearer ";
  const ok =
    header.startsWith(prefix) &&
    timingSafeEqual(header.slice(prefix.length), env.MAC_SHARED_SECRET);
  if (ok) return null;
  return new Response(JSON.stringify({ error: "unauthorized" }), {
    status: 401,
    headers: { "content-type": "application/json" },
  });
}
