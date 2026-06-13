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

export interface LlmEnv {
  ANTHROPIC_API_KEY: string;
}

const SET_LAMP_TOOL = {
  name: "set_lamp",
  description: "Apply a lamp command parsed from the user's natural-language request.",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      action: {
        type: "string",
        enum: ["on", "off", "set"],
        description: "on/off toggle power; set adjusts brightness/color (also turns the lamp on).",
      },
      brightness: { type: "integer", minimum: 0, maximum: 100, description: "Brightness percent." },
      color_temp_k: {
        type: "integer",
        minimum: 2700,
        maximum: 6500,
        description: "Color temperature in Kelvin: warm≈2700, neutral≈4000, cool≈5500, daylight≈6500.",
      },
    },
    required: ["action"],
  },
} as const;

const SYSTEM = [
  "You translate a short natural-language request about a desk lamp into a single set_lamp tool call.",
  "The lamp is tunable white: brightness 0-100 percent and color temperature 2700K (warm) to 6500K (cool).",
  "Map fuzzy words to Kelvin: warm≈2700, neutral≈4000, cool≈5500, daylight≈6500.",
  'Use "off" for turning the lamp off (no other fields). Use "on" to turn it on (optionally with brightness/color).',
  'Use "set" to adjust brightness/color whether the lamp is on or off (it also turns the lamp on).',
  "Always respond by calling set_lamp. Never answer in prose.",
].join(" ");

const STRICT_SUFFIX =
  " Be precise: respond ONLY with a set_lamp tool call whose fields are strictly within range.";

/** Live LlmClient backed by the Anthropic Messages API. `fetchImpl` is injectable for tests. */
export function makeLlmClient(env: LlmEnv, fetchImpl: typeof fetch = fetch): LlmClient {
  return {
    async complete(emailBody: string, strict: boolean): Promise<unknown> {
      const res = await fetchImpl("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: {
          "x-api-key": env.ANTHROPIC_API_KEY,
          "anthropic-version": "2023-06-01",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          model: "claude-haiku-4-5",
          max_tokens: 256,
          system: strict ? SYSTEM + STRICT_SUFFIX : SYSTEM,
          tools: [SET_LAMP_TOOL],
          tool_choice: { type: "tool", name: "set_lamp" },
          messages: [{ role: "user", content: emailBody }],
        }),
      });
      if (!res.ok) throw new Error(`anthropic request failed: ${res.status}`);
      const data = (await res.json()) as { content?: Array<Record<string, unknown>> };
      const toolUse = (data.content ?? []).find(
        (b) => b.type === "tool_use" && b.name === "set_lamp",
      );
      return toolUse?.input ?? null;
    },
  };
}
