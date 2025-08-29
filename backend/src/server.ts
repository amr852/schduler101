import "dotenv/config";
import express from "express";
import cors from "cors";
import morgan from "morgan";
import health from "./routes/health";
import events from "./routes/events";
import me from "./routes/me";
import { applyTenant } from "./lib/tenant";

const app = express();
app.use(cors());
app.use(express.json());
app.use(morgan("dev"));

app.use(applyTenant);
app.use(health);
app.use("/events", events);
app.use("/me", me);

const port = Number(process.env.PORT || 3000);
app.listen(port, () => console.log(`API on http://localhost:${port}`));
