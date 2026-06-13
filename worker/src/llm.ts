import { LlmCommandSchema, type LlmCommand } from "./schema";

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

/**
 * Normalize a raw tool-use input into an LlmCommand, or null if it doesn't conform.
 * Clamps brightness to 0-100 and color_temp_k to 2700-6500 (the model may overshoot
 * a named bucket); strips brightness/color from "off".
 */
export function parseLlmToolUse(raw: unknown): LlmCommand | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;

  const candidate: Record<string, unknown> = { action: r.action };
  if (r.action !== "off") {
    if (typeof r.brightness === "number") {
      candidate.brightness = clamp(Math.round(r.brightness), 0, 100);
    }
    if (typeof r.color_temp_k === "number") {
      candidate.color_temp_k = clamp(Math.round(r.color_temp_k), 2700, 6500);
    }
  }

  const result = LlmCommandSchema.safeParse(candidate);
  return result.success ? result.data : null;
}

export interface LlmClient {
  /**
   * Returns the model's raw tool-use input object (or null if the model produced
   * no usable tool call). Throws on transport / API errors so the caller can
   * distinguish "couldn't reach the model" from "model produced garbage".
   */
  complete(emailBody: string, strict: boolean): Promise<unknown>;
}

/**
 * Extract a command from the email body. Tries once normally; on an invalid
 * result, retries once with a stricter instruction. Returns null if both
 * attempts fail to validate. Re-throws transport errors from the client.
 */
export async function extractCommand(
  emailBody: string,
  client: LlmClient,
): Promise<LlmCommand | null> {
  for (const strict of [false, true]) {
    const raw = await client.complete(emailBody, strict);
    const command = parseLlmToolUse(raw);
    if (command) return command;
  }
  return null;
}
