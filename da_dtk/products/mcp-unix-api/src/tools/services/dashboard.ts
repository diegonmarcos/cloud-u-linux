// B) User-Services — Dashboard (unified status + JSON data dump)
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh } from "../../exec.js";

export function registerDashboardTools(server: McpServer) {
  server.tool(
    "services.dashboard.status",
    "Show unified dashboard: HM, mesh, git, drives, sync, servers, security",
    {},
    async () => {
      const result = sh(`connect status 2>&1`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );

  server.tool(
    "services.dashboard.logs",
    "JSON dump of all connect data (mesh, git, drives, sync, servers, gauges)",
    {
      section: z.enum(["all", "mesh", "git", "drives", "sync", "servers", "services", "webservers", "home_manager", "security", "gauges", "alerts"])
        .optional().describe("Section to extract (default: all)"),
    },
    async ({ section }) => {
      const jqFilter = section && section !== "all" ? ` | jq '.${section}'` : "";
      const result = sh(`connect logs 2>&1${jqFilter}`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );
}
