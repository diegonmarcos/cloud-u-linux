// A) Infra-Dev — Web Servers (dev servers + code-server)
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../../exec.js";

export function registerWebServerTools(server: McpServer) {
  server.tool(
    "infra.web_servers.dev",
    "Control front-end dev servers (list/start/stop)",
    {
      action: z.enum(["list", "start", "stop", "status"]).describe("Server action"),
      project: z.string().optional().describe("Project name (for start/stop)"),
    },
    async ({ action, project }) => {
      const args = project ? `${action} ${project}` : action;
      const result = sh(`server ${args} 2>&1`, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`server ${action}`, result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "infra.web_servers.code",
    "Control code-server (local/lan/stop/log/status)",
    {
      action: z.enum(["local", "lan", "stop", "log", "status"]).optional()
        .describe("Action (default: status)"),
    },
    async ({ action }) => {
      const result = sh(`code ${action ?? ""} 2>&1`, { timeout: 15_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );
}
