import { z } from "zod";

export const rangeQuerySchema = z.object({
  from: z.string().datetime().optional(),
  to: z.string().datetime().optional(),
  userId: z.string().uuid().optional()
});

export const createEventSchema = z.object({
  calendar_id: z.string().uuid(),
  title: z.string().min(1),
  description: z.string().optional(),
  location: z.string().optional(),
  start_utc: z.string().datetime(),
  end_utc: z.string().datetime(),
  all_day: z.boolean().optional().default(false),
  status: z.enum(["tentative","confirmed","cancelled"]).optional().default("confirmed"),
  visibility: z.enum(["private","public","busy"]).optional().default("private"),
  created_by: z.string().uuid(),
  participants: z.array(z.string().uuid()).optional().default([]),
  reminders: z.array(z.object({
    minutes_before: z.number().int().nonnegative(),
    channel: z.enum(["push","email","sms"]).optional().default("push"),
    for_user_id: z.string().uuid().optional()
  })).optional().default([])
});
