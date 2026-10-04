// Section 3: dashboards — local monitors, sysstat, journal-dash, connect, remote monitors
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { dtk, run, reply, CONNECT } from "../exec.js";

export function register(server: McpServer) {
  // ── local monitors ─────────────────────────────────────────
  server.tool(
    "dtk_monitor_local",
    "Local system monitors (tmux-based): btop, iotop, top-batch",
    {
      tool: z.enum(["btop", "iotop", "top-batch"]).describe("Monitor tool"),
    },
    async ({ tool }) => {
      const map: Record<string, string> = { btop: "30a", iotop: "30b", "top-batch": "30c" };
      return reply(`monitor:${tool}`, dtk(map[tool]!));
    },
  );

  // ── sysstat ────────────────────────────────────────────────
  server.tool(
    "dtk_sysstat",
    "Sysstat monitoring tools: iostat, mpstat, pidstat, sar, vmstat",
    {
      tool: z.enum(["iostat", "mpstat", "pidstat", "sar", "vmstat"]).describe("Sysstat tool"),
    },
    async ({ tool }) => {
      const map: Record<string, string> = { iostat: "31a", mpstat: "31b", pidstat: "31c", sar: "31d", vmstat: "31e" };
      return reply(`sysstat:${tool}`, dtk(map[tool]!));
    },
  );

  // ── journal-dash ───────────────────────────────────────────
  server.tool(
    "dtk_journal_dash",
    "Journal dashboard views (tmux multi-pane): transport, priority, unit, watch",
    {
      view: z.enum(["transport", "priority", "unit", "watch"]).describe("Journal view (transport=4-pane, priority=8-pane, unit=4-pane, watch=n35)"),
    },
    async ({ view }) => {
      const map: Record<string, string> = { transport: "32a", priority: "32b", unit: "32c", watch: "32d" };
      return reply(`journal:${view}`, dtk(map[view]!));
    },
  );

  // ── connect ────────────────────────────────────────────────
  server.tool(
    "dtk_connect",
    "Cloud Connect dashboard TUI — unified view: settings, mesh, git, fuse-drives, sync, data-servers, web-servers, hm-flakes",
    {},
    async () => reply("connect", dtk("33")),
  );

  // ── remote monitors ────────────────────────────────────────
  server.tool(
    "dtk_monitor_remote",
    "Remote multi-VM monitors (tmux 4-pane): btop-dash, journal-dash, docker-stats",
    {
      tool: z.enum(["btop-dash", "journal-dash", "docker-stats"]).describe("Remote monitor"),
    },
    async ({ tool }) => {
      const map: Record<string, string> = { "btop-dash": "34a", "journal-dash": "34b", "docker-stats": "34c" };
      return reply(`remote:${tool}`, dtk(map[tool]!));
    },
  );
}
