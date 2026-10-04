// A) Infra-Dev — Sync (rclone sync/bisync rules)
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../../exec.js";

export function registerSyncTools(server: McpServer) {
  server.tool(
    "infra.sync.control",
    "Control rclone sync rules and background jobs",
    {
      action: z.enum(["sync-run", "sync-run-bg", "sync-list", "sync-status", "sync-jobs", "sync-kill", "sync-clear-jobs"])
        .describe("Sync action"),
    },
    async ({ action }) => {
      const result = sh(`connect ${action} 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${action}`, result) }],
        isError: !result.ok,
      };
    }
  );
}
