import { Router } from "express";
import { getPool } from "../db";
import sql from "mssql";
const r = Router();

r.get("/next-event", async (req, res) => {
  const userId = req.query.userId as string | undefined;
  if (!userId) return res.status(400).json({ error: "userId is required" });
  try {
    const pool = await getPool();
    const result = await pool.request()
      .input("userId", sql.UniqueIdentifier, userId)
      .query("SELECT * FROM app.fn_next_event(@userId);");
    res.json(result.recordset[0] ?? null);
  } catch (e:any) { res.status(500).json({ error: e.message }); }
});

export default r;
