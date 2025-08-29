import sql from "mssql";

let pool: sql.ConnectionPool | null = null;

function buildConfig(): sql.config {
  // Accept either:
  //  A) DB_SERVER="localhost\\SQLEXPRESS"
  //  B) DB_SERVER="localhost" + DB_INSTANCE="SQLEXPRESS"
  //  C) DB_SERVER="127.0.0.1" + DB_PORT="1433"
  let server = process.env.DB_SERVER!;
  let instanceName = process.env.DB_INSTANCE || undefined;
  let port = process.env.DB_PORT ? Number(process.env.DB_PORT) : undefined;

  if (server.includes("\\")) {
    const [host, instance] = server.split("\\", 2);
    server = host;
    instanceName = instance;
    port = undefined; // instance name and port are mutually exclusive
  }

  // Auth mode:
  // DB_AUTH = "sql" (default)  -> DB_USER / DB_PASSWORD
  // DB_AUTH = "ntlm"           -> DB_DOMAIN / DB_USERNAME / DB_PASSWORD
  const authMode = (process.env.DB_AUTH || "sql").toLowerCase();

  const base: any = {
    server,
    database: process.env.DB_DATABASE!,
    options: {
      instanceName,                     // used only if set
      encrypt: process.env.DB_ENCRYPT === "true",
      trustServerCertificate: process.env.DB_TRUST_SERVER_CERT === "true",
      enableArithAbort: true,
    },
  };

  if (port) base.port = port;

  if (authMode === "ntlm") {
    base.authentication = {
      type: "ntlm",
      options: {
        domain: process.env.DB_DOMAIN || "",          // e.g. "AMR"
        userName: process.env.DB_USERNAME || "",      // e.g. "haitham"
        password: process.env.DB_PASSWORD || "",      // can be blank if SSPI/SSO is configured
      },
    };
  } else {
    // default: SQL authentication
    base.user = process.env.DB_USER!;
    base.password = process.env.DB_PASSWORD!;
  }

  return base as sql.config;
}

export async function getPool() {
  if (pool && pool.connected) return pool;
  pool = await new sql.ConnectionPool(buildConfig()).connect();
  return pool;
}

export async function setTenantContext(tenantId = process.env.TENANT_ID!) {
  if (!tenantId) return; // safe no-op if you haven't enabled RLS
  try {
    const p = await getPool();
    await p
      .request()
      .input("key", sql.NVarChar, "tenant_id")
      .input("value", sql.NVarChar, tenantId)
      .execute("sp_set_session_context");
  } catch {
    // ignore if RLS not configured
  }
}
