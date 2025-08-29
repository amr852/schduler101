import { Router } from "express";
import { getPool } from "../db";
const r = Router();

r.get("/healthz", async (_req, res) => {
  try {
    const pool = await getPool();
    await pool.request().query("SELECT 1");
    res.json({ ok: true });
  } catch (e: any) {
    console.error("HEALTH DB ERROR:", e);              // <- see terminal
    res.status(500).json({ ok: false, error: e.message }); // <- see browser
  }
});

export default r;
