#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { register as registerCmdsLocal } from "./tools/cmds-local.js";
import { register as registerCmdsCloud } from "./tools/cmds-cloud.js";
import { register as registerDashboards } from "./tools/dashboards.js";
import { register as registerSetups } from "./tools/setups.js";
import { register as registerInfos } from "./tools/infos.js";

const log = (msg: string) => process.stderr.write(`[dtk-mcp] ${msg}\n`);

async function main() {
  const server = new McpServer({
    name: "dtk-mcp",
    version: "1.0.0",
  });

  // Section 1: cmds-local (aliases, webhooks, commands)
  registerCmdsLocal(server);
  // Section 2: cmds-cloud (VM, orchestrate, local, desktop, VPS, SSH, mode)
  registerCmdsCloud(server);
  // Section 3: dashboards (monitors, sysstat, journal, connect, remote)
  registerDashboards(server);
  // Section 4: setups (containers, nixos, shell, git, sys, llms, vault)
  registerSetups(server);
  // Section 5: infos (help, info, deps, engines, install, ssh-gcp, generic runner)
  registerInfos(server);

  const transport = new StdioServerTransport();
  log("Starting dtk-mcp v1.0.0 (29 tools covering ~210 DTK commands)...");
  await server.connect(transport);
  log("Connected via stdio transport");
}

main().catch((err) => {
  log(`Fatal: ${err}`);
  process.exit(1);
});
