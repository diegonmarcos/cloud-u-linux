// Section 4: setups — containers, nixos, shell, git, sys, llms, vault
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { dtk, run, reply, CONTAINERS, FISH_TOOLS, FISH_SHELL, LLMS, VAULT } from "../exec.js";

export function register(server: McpServer) {
  // ── containers ─────────────────────────────────────────────
  server.tool(
    "dtk_containers",
    "Launch dev containers: nix or apt image × cli, gui, or tty profile",
    {
      image: z.enum(["nix", "apt"]).describe("Container image variant"),
      profile: z.enum(["cli", "gui", "tty"]).describe("Profile: cli=full shell, gui=wayland/X11, tty=headless"),
    },
    async ({ image, profile }) => {
      // 40a=nix, 40b=apt; 0=cli, 1=gui, 2=tty
      const imgCode = image === "nix" ? "a" : "b";
      const profCode = profile === "cli" ? "0" : profile === "gui" ? "1" : "2";
      return reply(`containers:${image}:${profile}`, dtk(`40${imgCode}${profCode}`));
    },
  );

  // ── nixos / home-manager ───────────────────────────────────
  server.tool(
    "dtk_hm",
    "Home-manager container profiles: cli, gui, tty",
    {
      profile: z.enum(["cli", "gui", "tty"]).describe("HM profile"),
    },
    async ({ profile }) => {
      const profCode = profile === "cli" ? "0" : profile === "gui" ? "1" : "2";
      return reply(`hm:${profile}`, dtk(`41a${profCode}`));
    },
  );

  // ── shell ──────────────────────────────────────────────────
  server.tool(
    "dtk_shell_setup",
    "Shell setup: fish+tools (with sudo), fish-only (no sudo), konsole quick-cmds config",
    {
      action: z.enum(["fish-tools", "fish", "konsole-cfg"]).describe("Shell setup action"),
    },
    async ({ action }) => {
      if (action === "fish-tools") return reply("shell:fish-tools", run("sh", [FISH_TOOLS]));
      if (action === "fish") return reply("shell:fish", run("sh", [FISH_SHELL]));
      return reply("shell:konsole-cfg", dtk("42c"));
    },
  );

  // ── git ────────────────────────────────────────────────────
  server.tool(
    "dtk_git_clone",
    "Clone all repos via HTTPS or SSH",
    {
      protocol: z.enum(["https", "ssh"]).describe("Clone protocol"),
    },
    async ({ protocol }) => {
      const code = protocol === "https" ? "43a" : "43b";
      return reply(`git-clone:${protocol}`, dtk(code));
    },
  );

  // ── sys ────────────────────────────────────────────────────
  server.tool(
    "dtk_sudoers",
    "Configure passwordless sudo (NOPASSWD) for current user",
    {},
    async () => reply("sudoers", dtk("44a")),
  );

  // ── llms ───────────────────────────────────────────────────
  server.tool(
    "dtk_llms",
    "Install/configure LLM tools: goose, claude/gemini, malloc-termux",
    {
      tool: z.enum(["goose", "claude", "malloc-termux"]).describe("LLM tool to set up"),
    },
    async ({ tool }) => reply(`llms:${tool}`, run("sh", [LLMS, tool])),
  );

  // ── vault ──────────────────────────────────────────────────
  server.tool(
    "dtk_vault",
    "Vault operations: build vault structure or export env vars",
    {
      action: z.enum(["build", "env-export"]).describe("Vault action"),
    },
    async ({ action }) => reply(`vault:${action}`, run("sh", [VAULT, action])),
  );
}
