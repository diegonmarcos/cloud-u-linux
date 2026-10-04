// Section 1: cmds-local — aliases, webhooks, commands (28 scripts)
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { dtk, run, reply, WEBHOOKS } from "../exec.js";

export function register(server: McpServer) {
  // ── aliases ────────────────────────────────────────────────
  server.tool(
    "dtk_aliases",
    "List all shell aliases/functions by category (3-column format)",
    {},
    async () => reply("aliases", dtk("10")),
  );

  // ── webhooks ───────────────────────────────────────────────
  server.tool(
    "dtk_webhooks",
    "ntfy bridge: once/watch fetch from local CMD topic; post to local OUT; cmd sends to remote node's CMD; test runs local round-trip",
    {
      mode: z.enum(["once", "watch", "post", "cmd", "test"])
        .describe("once=fetch+run from local CMD; watch=loop; post=announce on local OUT; cmd=send command to remote node's CMD topic; test=local round-trip self-test"),
      target: z.string().optional()
        .describe("Required for mode=cmd. Target receiver hostname (must match its `hostname -s`); topic = dtk-cmd-<target>"),
      message: z.string().optional()
        .describe("Required for mode=cmd (the command to execute). Optional for mode=post (default: '<host> webhook ready')."),
    },
    async ({ mode, target, message }) => {
      const args: string[] = [WEBHOOKS, mode];
      if (mode === "cmd") {
        if (!target || !message) {
          return reply("webhooks", { text: "mode=cmd requires both 'target' and 'message'", ok: false });
        }
        args.push(target, message);
      } else if (mode === "post" && message) {
        args.push(message);
      }
      return reply("webhooks", run("sh", args));
    },
  );

  // ── commands ───────────────────────────────────────────────
  server.tool(
    "dtk_commands_list",
    "List all available quick commands (28 operational scripts)",
    {},
    async () => reply("commands", dtk("12")),
  );

  server.tool(
    "dtk_command",
    "Run a quick command by number: 0=fish-install, 1=flush-ipt, 2=rst-sshd, 3=rst-wg, 4=rst-docker, 5=stop-docker, 6=start-docker, 7=docker-ps, 8=wg-status, 9=iptables, 10=free-mem, 11=disk-usage, 12=kill-wdog, 13=journal-sil, 14=fix-journal, 15=full-rescue, 16=tmux-web, 17=fix-wg-ip, 18=guardrail, 19=fix-nix-path, 20=ssh-restart, 21=wg-debug, 22=sshd-debug, 23=vm-health, 24=fix-all, 25=mem-emerg, 26=hm-rescue, 27=kill-docker-compose",
    {
      n: z.number().min(0).max(27).describe("Command number (0-27)"),
    },
    async ({ n }) => {
      // DTK shortcode: 12<N> where N maps 0→0, 1→1, ..., 9→9, 10→10
      const shortcode = `12${n}`;
      return reply(`command-${n}`, dtk(shortcode));
    },
  );
}
