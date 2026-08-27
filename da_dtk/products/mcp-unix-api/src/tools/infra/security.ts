// A) Infra-Dev — Security (firewalls, WireGuard peers, Caddy routes)
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { sh } from "../../exec.js";

export function registerSecurityTools(server: McpServer) {
  server.tool(
    "infra.security.status",
    "Show security dashboard (firewalls, WireGuard peers, Caddy routes)",
    {},
    async () => {
      const result = sh(`connect logs 2>&1 | jq '.security'`, { timeout: 30_000 });
      return { content: [{ type: "text", text: result.stdout || result.stderr }] };
    }
  );
}
