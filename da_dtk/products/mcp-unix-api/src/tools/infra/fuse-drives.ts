// A) Infra-Dev — Fuse Drives (rclone cloud mounts)
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../../exec.js";

export function registerFuseDrivesTools(server: McpServer) {
  server.tool(
    "infra.drives.control",
    "Control rclone cloud drive mounts (GDrive, etc)",
    {
      action: z.enum(["mount-drive", "unmount-drive", "mount-all-drives", "unmount-all-drives", "toggle-drives"])
        .describe("Drive action"),
      name: z.string().optional().describe("Drive name (for mount-drive, unmount-drive)"),
    },
    async ({ action, name }) => {
      const args = name ? `${action} ${name}` : action;
      const result = sh(`connect ${args} 2>&1`, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${args}`, result) }],
        isError: !result.ok,
      };
    }
  );
}
