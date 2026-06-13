import type { LlmCommand } from "./schema";

/** Collapse all whitespace (newlines, tabs, runs of spaces) to single spaces and trim. */
function normaliseRequest(body: string): string {
  return body.replace(/\s+/g, " ").trim();
}

/** Truncate to 200 chars, appending "…" when truncation occurs. */
function truncate(text: string): string {
  if (text.length <= 200) return text;
  return text.slice(0, 200) + "…";
}

/** Format the first line that echoes the original request body. */
function requestLine(requestBody: string): string {
  const normalised = truncate(normaliseRequest(requestBody));
  return `Got request — "${normalised}"`;
}

/** Map a Kelvin value to a human word. */
function kelvinWord(k: number): string {
  if (k <= 3000) return "warm";
  if (k <= 4500) return "neutral";
  if (k <= 5500) return "cool";
  return "daylight";
}

/** Build the model-summary fragment for line 2. */
function modelSummary(cmd: LlmCommand): string {
  if (cmd.action === "off") return "off";

  const parts: string[] = [cmd.action];
  if (cmd.brightness !== undefined) {
    parts.push(`brightness ${cmd.brightness}`);
  }
  if (cmd.color_temp_k !== undefined) {
    parts.push(`color ${cmd.color_temp_k}K (${kelvinWord(cmd.color_temp_k)})`);
  }
  return parts.join(", ");
}

/** Build the human-readable execution phrase for line 3. */
function humanPhrase(cmd: LlmCommand): string {
  if (cmd.action === "off") return "turning the lamp off";

  let phrase = "turning the lamp on";
  if (cmd.brightness !== undefined) {
    phrase += ` at ${cmd.brightness}%`;
  }
  if (cmd.color_temp_k !== undefined) {
    const word = kelvinWord(cmd.color_temp_k);
    phrase += `, ${word} (${cmd.color_temp_k}K)`;
  }
  return phrase;
}

/**
 * Returns a 3-line processing log confirming a queued command.
 *
 * Line 1: echoes the request body (whitespace-collapsed, truncated to 200 chars)
 * Line 2: summarises the parsed LLM command fields
 * Line 3: describes the action in plain English
 */
export function formatQueuedReply(requestBody: string, cmd: LlmCommand): string {
  return [
    requestLine(requestBody),
    `Got response from the model — ${modelSummary(cmd)}`,
    `Executing — ${humanPhrase(cmd)}`,
  ].join("\n");
}

/**
 * Returns a 2-line reply when the LLM could not parse the email into a command.
 *
 * Line 1: echoes the request body (whitespace-collapsed, truncated to 200 chars)
 * Line 2: fixed hint message
 */
export function formatUnparseableReply(requestBody: string): string {
  return [
    requestLine(requestBody),
    "Couldn't understand that command. Try e.g. 'on, warm, 30%'.",
  ].join("\n");
}
