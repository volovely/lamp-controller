import { z } from "zod";

// Mirrors shared/command-schema.json
export const CommandSchema = z.object({
  id: z.string(),
  action: z.enum(["on", "off", "set"]),
  brightness: z.number().int().min(0).max(100).optional(),
  color_temp_k: z.number().int().min(2700).max(6500).optional(),
  duration_minutes: z.number().int().min(1).max(1440).optional(),
  created_at: z.string(),
  source_msg_id: z.string(),
});

export type Command = z.infer<typeof CommandSchema>;

/** Returns the parsed Command, or null if the value does not conform. */
export function parseCommand(value: unknown): Command | null {
  const result = CommandSchema.safeParse(value);
  return result.success ? result.data : null;
}
