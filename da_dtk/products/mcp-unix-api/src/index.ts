#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

// A) Infra-Dev
import { registerSystemShellTools } from "./tools/infra/system-shell.js";
import { registerHomeManagerTools } from "./tools/infra/home-manager.js";
import { registerMeshTools } from "./tools/infra/mesh.js";
import { registerGitSyncTools } from "./tools/infra/git-sync.js";
import { registerFuseDrivesTools } from "./tools/infra/fuse-drives.js";
import { registerSyncTools } from "./tools/infra/sync.js";
import { registerDataServerTools } from "./tools/infra/data-servers.js";
import { registerWebServerTools } from "./tools/infra/web-servers.js";
import { registerSecurityTools } from "./tools/infra/security.js";

// B) User-Services
import { registerEmailTools } from "./tools/services/email.js";
import { registerDashboardTools } from "./tools/services/dashboard.js";

import { startMcpHttpServer } from "./http.js";
import { PLATFORM } from "./paths.js";

// All logging to stderr (stdout = JSON-RPC in stdio mode)
const log = (msg: string) => process.stderr.write(`[unix-mcp] ${msg}\n`);

function createServer(): McpServer {
  const server = new McpServer({
    name: "unix-mcp",
    version: "2.0.0",
  });

  // ── A) Infra-Dev ──────────────────────────────────
  registerSystemShellTools(server);   // 15: sys_* + shell_* + npm_*
  registerHomeManagerTools(server);   // 10: connect_hm + nix_* + nix_drift_*
  registerMeshTools(server);          //  2: connect_mesh_*
  registerGitSyncTools(server);       //  6: connect_git/gacp + git_*
  registerFuseDrivesTools(server);    //  1: connect_drives
  registerSyncTools(server);          //  1: connect_sync
  registerDataServerTools(server);    //  1: connect_server
  registerWebServerTools(server);     //  2: connect_dev_server + connect_code_server
  registerSecurityTools(server);      //  1: connect_security

  // ── B) User-Services ──────────────────────────────
  registerEmailTools(server);         //  5: email_*
  registerDashboardTools(server);     //  2: connect_status + connect_logs

  return server;
}

// ── Transport selection ─────────────────────────────
// --http or MCP_HTTP=1 → persistent HTTP server (no reconnect needed)
// default → stdio (standard MCP transport)
const useHttp = process.argv.includes("--http") || process.env.MCP_HTTP === "1";

async function main() {
  log(`Starting unix-mcp v2.0.0 (46 tools, platform=${PLATFORM})...`);

  if (useHttp) {
    const port = parseInt(process.env.MCP_HTTP_PORT ?? "3200", 10);
    await startMcpHttpServer(createServer, port);
    log(`HTTP transport on 127.0.0.1:${port}/mcp`);
  } else {
    const server = createServer();
    const transport = new StdioServerTransport();
    await server.connect(transport);
    log("Connected via stdio transport");
  }
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
