// A) Infra-Dev — Data Servers (WebDAV, SFTP, HTTP, Unison)
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../../exec.js";

export function registerDataServerTools(server: McpServer) {
  server.tool(
    "infra.data_servers.control",
    "Control data servers (WebDAV, SFTP, HTTP+Eruda, Unison)",
    {
      action: z.enum(["server-start", "server-stop", "server-restart", "server-mode", "server-status", "bisync"])
        .describe("Server action"),
    },
    async ({ action }) => {
      const result = sh(`connect ${action} 2>&1`, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${action}`, result) }],
        isError: !result.ok,
      };
    }
  );
}
