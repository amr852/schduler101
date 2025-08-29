import { setTenantContext } from "../db";
import { Request, Response, NextFunction } from "express";

export async function applyTenant(_req: Request, _res: Response, next: NextFunction) {
  await setTenantContext();
  next();
}
