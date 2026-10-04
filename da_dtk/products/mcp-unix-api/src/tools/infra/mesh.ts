// A) Infra-Dev — Mesh (WireGuard VPN, VM mounts, OCI lifecycle)
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../../exec.js";

export function registerMeshTools(server: McpServer) {
  server.tool(
    "infra.mesh.status",
    "Show WireGuard VPN mesh status (VMs, connectivity, peers)",
    {},
    async () => {
      const result = sh(`connect logs 2>&1 | jq '.mesh'`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );

  server.tool(
    "infra.mesh.control",
    "Control VPN mesh: VM mounts (SSHFS) and OCI Flex lifecycle",
    {
      action: z.enum([
        "mount-vm", "unmount-vm", "mount-all-vm", "unmount-all",
        "mount-phone", "unmount-phone",
        "flex-start", "flex-stop", "flex-reset", "flex-status",
      ]).describe("Mesh action"),
      target: z.string().optional().describe("VM or resource name (for mount-vm, unmount-vm, flex-*)"),
    },
    async ({ action, target }) => {
      const args = target ? `${action} ${target}` : action;
      const result = sh(`connect ${args} 2>&1`, { timeout: 30_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${args}`, result) }],
        isError: !result.ok,
      };
    }
  );
}
