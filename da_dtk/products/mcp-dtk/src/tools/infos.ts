// Section 5: infos — help, sys-info, tools, mounts, deps
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { dtk, run, reply, ENGINES, INSTALL, SSH_SH } from "../exec.js";

export function register(server: McpServer) {
  // ── help ───────────────────────────────────────────────────
  server.tool(
    "dtk_help",
    "Show DTK help — all available commands and shortcodes",
    {},
    async () => reply("help", dtk("50")),
  );

  // ── infos ──────────────────────────────────────────────────
  server.tool(
    "dtk_info",
    "System information: sys-info, sys-net-resource, sys-paths, sys-envs, tools-table, tools-help, sys-mounts, or all",
    {
      section: z.enum(["all", "sys-info", "sys-net-resource", "sys-paths", "sys-envs", "tools-table", "tools-help", "sys-mounts"])
        .describe("Info section (all=everything)"),
    },
    async ({ section }) => {
      if (section === "all") return reply("infos:all", dtk("51"));
      const map: Record<string, string> = {
        "sys-info": "51a", "sys-net-resource": "51b", "sys-paths": "51c",
        "sys-envs": "51d", "tools-table": "51e", "tools-help": "51f", "sys-mounts": "51g",
      };
      return reply(`infos:${section}`, dtk(map[section]!));
    },
  );

  // ── deps ───────────────────────────────────────────────────
  server.tool(
    "dtk_deps",
    "Dependency analysis: drift (declared vs installed) or solver (full toolchain check)",
    {
      action: z.enum(["drift", "solver"]).describe("drift=summary, solver=detailed check"),
    },
    async ({ action }) => {
      const code = action === "drift" ? "52a" : "52b";
      return reply(`deps:${action}`, dtk(code, 180_000));
    },
  );

  // ── engines ────────────────────────────────────────────────
  server.tool(
    "dtk_engines",
    "Launch build engines: nixos-host, home-desktop, home-termux, cloud-service, front-end",
    {
      engine: z.enum(["1", "2", "3", "4", "5"]).optional()
        .describe("1=nixos-host, 2=home-desktop, 3=home-termux, 4=cloud-service, 5=front-end"),
    },
    async ({ engine }) => reply("engines", run("sh", [ENGINES, engine ?? ""])),
  );

  // ── install ────────────────────────────────────────────────
  server.tool(
    "dtk_install",
    "Install full dev toolchain (auto-detects distro: nix, arch, debian, fedora, macos, termux)",
    {},
    async () => reply("install", run("sh", [INSTALL], 300_000)),
  );

  // ── ssh (GCP serial/rescue) ────────────────────────────────
  server.tool(
    "dtk_ssh_gcp",
    "GCP VM access: serial console, SSH, rescue (flush iptables), reset, kill-watchdog",
    {
      mode: z.enum(["serial", "ssh", "rescue", "reset", "kill-watchdog"]).describe("Access mode"),
      vm: z.enum(["gcp-proxy", "gcp-t4"]).describe("GCP VM"),
    },
    async ({ mode, vm }) => reply(`ssh-gcp:${mode}:${vm}`, run("sh", [SSH_SH, mode, vm])),
  );

  // ── generic shortcode runner ───────────────────────────────
  server.tool(
    "dtk_run",
    "Run any DTK shortcode directly (e.g. '51a', '20d', '1215', '42a'). Use when no specific tool matches.",
    {
      shortcode: z.string().describe("DTK shortcode (e.g. '51a', '20f', '1224')"),
    },
    async ({ shortcode }) => reply(`dtk:${shortcode}`, dtk(shortcode)),
  );
}
