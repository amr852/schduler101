import { Router } from "express";
import { getPool } from "../db";
import sql from "mssql";
import { createEventSchema, rangeQuerySchema } from "../lib/validators";

const r = Router();

r.get("/", async (req, res) => {
  const parsed = rangeQuerySchema.safeParse(req.query);
  if (!parsed.success) return res.status(400).json(parsed.error);
  const { from, to, userId } = parsed.data;

  try {
    const pool = await getPool();
    const q = `
      SELECT ua.user_id, e.*
      FROM app.v_user_agenda ua
      JOIN app.events e ON e.event_id = ua.event_id
      WHERE (@userId IS NULL OR ua.user_id = @userId)
        AND (@from IS NULL OR e.end_utc   >= @from)
        AND (@to   IS NULL OR e.start_utc <= @to)
      ORDER BY e.start_utc ASC;
    `;
    const result = await pool.request()
      .input("userId", userId ? sql.UniqueIdentifier : sql.NVarChar, userId ?? null)
      .input("from", from ? sql.DateTime2 : sql.NVarChar, from ?? null)
      .input("to",   to   ? sql.DateTime2 : sql.NVarChar, to   ?? null)
      .query(q);
    res.json(result.recordset);
  } catch (e:any) { res.status(500).json({ error: e.message }); }
});

r.post("/", async (req, res) => {
  const parsed = createEventSchema.safeParse(req.body);
  if (!parsed.success) return res.status(400).json(parsed.error);
  const d = parsed.data;

  try {
    const pool = await getPool();
    const result = await pool.request()
      .input("calendar_id", sql.UniqueIdentifier, d.calendar_id)
      .input("title", sql.NVarChar(300), d.title)
      .input("description", sql.NVarChar(sql.MAX), d.description ?? null)
      .input("location", sql.NVarChar(400), d.location ?? null)
      .input("start_utc", sql.DateTime2, new Date(d.start_utc))
      .input("end_utc", sql.DateTime2, new Date(d.end_utc))
      .input("all_day", sql.Bit, d.all_day ?? false)
      .input("status", sql.NVarChar(24), d.status)
      .input("visibility", sql.NVarChar(24), d.visibility)
      .input("created_by", sql.UniqueIdentifier, d.created_by)
      .input("participants_json", sql.NVarChar(sql.MAX), JSON.stringify(d.participants ?? []))
      .input("reminders_json", sql.NVarChar(sql.MAX), JSON.stringify(d.reminders ?? []))
      .execute("app.sp_create_event");

    res.status(201).json({ event_id: result.recordset[0]?.event_id });
  } catch (e:any) { res.status(500).json({ error: e.message }); }
});

export default r;
