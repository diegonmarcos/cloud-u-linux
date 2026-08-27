// Section 2: cmds-cloud — quick-cmds (VM/orchestrate/local/desktop), VPS, SSH, mode
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { cco, dtk, reply } from "../exec.js";

const VMS = ["gcp-proxy", "oci-mail", "oci-analytics", "oci-apps"] as const;

const VM_ACTIONS_COMMON = [
  "ssh", "ssh-dropbear",
  "htop", "journalctl-f",
  "journal-docker", "journal-sshd", "journal-wg", "journal-cinit", "journal-kernel", "journal-errors",
  "systemctl-status", "systemctl-list",
  "docker-start", "docker-stop", "docker-ps", "docker-stats", "docker-exec",
  "dashboard",
] as const;

const VM_ACTIONS_OCI = ["oci-start", "oci-stop", "oci-reset", "oci-serial"] as const;
const VM_ACTIONS_GCP = ["gcloud-start", "gcloud-stop", "gcloud-reset", "gcloud-serial"] as const;

const ALL_VM_ACTIONS = [...VM_ACTIONS_COMMON, ...VM_ACTIONS_OCI, ...VM_ACTIONS_GCP] as const;

const ORCHESTRATE_ACTIONS = [
  "mode-ssh", "mode-dropbear", "mode-serial", "mode-status",
  "htop", "journalctl-f",
  "journal-docker", "journal-sshd", "journal-wg", "journal-cinit", "journal-kernel", "journal-errors",
  "systemctl-status", "systemctl-list",
  "docker-start", "docker-stop", "docker-ps", "docker-stats",
  "dashboard-stats", "dashboard-journal", "script-push",
] as const;

const LOCAL_ACTIONS = [
  "htop", "journalctl-f",
  "journal-docker", "journal-sshd", "journal-wg", "journal-cinit", "journal-kernel", "journal-errors",
  "systemctl-status", "systemctl-list",
  "docker-start", "docker-stop", "docker-ps", "docker-stats", "docker-exec",
] as const;

const DESKTOP_ACTIONS = [
  "tui", "dtk", "dtk-install", "dtk-docker", "dtk-git-clone", "dtk-info", "dtk-commands", "dtk-ssh",
  "desktop-htop", "hm-switch", "nixos-switch",
  "git-status-all", "wg-status", "docker-ps-local", "free-mem", "disk-usage", "konsole-script-push",
] as const;

export function register(server: McpServer) {
  // ── quick-cmds: per-VM ─────────────────────────────────────
  server.tool(
    "dtk_vm",
    "Run a command on a specific VM via SSH (22 actions per VM including journal, docker, systemctl, cloud control)",
    {
      vm: z.enum(VMS).describe("Target VM"),
      action: z.enum(ALL_VM_ACTIONS).describe("Command to run (oci-* only for oci VMs, gcloud-* only for gcp VMs)"),
    },
    async ({ vm, action }) => reply(`vm:${vm}:${action}`, cco(`vm-${action}`, vm)),
  );

  // ── quick-cmds: orchestrate (all VMs) ──────────────────────
  server.tool(
    "dtk_orchestrate",
    "Run a command on ALL VMs simultaneously (orchestration mode)",
    {
      action: z.enum(ORCHESTRATE_ACTIONS).describe("Command to run across all VMs"),
    },
    async ({ action }) => {
      if (action.startsWith("mode-")) return reply(`orchestrate:${action}`, cco(action));
      return reply(`orchestrate:${action}`, cco(`all-${action}`));
    },
  );

  // ── quick-cmds: local ──────────────────────────────────────
  server.tool(
    "dtk_local",
    "Run a command locally (same as VM commands but on this machine)",
    {
      action: z.enum(LOCAL_ACTIONS).describe("Command to run locally"),
    },
    async ({ action }) => reply(`local:${action}`, cco(`local-${action}`)),
  );

  // ── quick-cmds: desktop ────────────────────────────────────
  server.tool(
    "dtk_desktop",
    "Desktop commands: hm-switch, nixos-switch, git-status-all, wg-status, docker-ps, etc.",
    {
      action: z.enum(DESKTOP_ACTIONS).describe("Desktop command"),
    },
    async ({ action }) => reply(`desktop:${action}`, cco(action)),
  );

  // ── VPS: cloud ─────────────────────────────────────────────
  server.tool(
    "dtk_vps_cloud",
    "Cloud provider commands: OCI instances, GCloud instances, billing",
    {
      action: z.enum(["oci-list", "oci-details", "oci-vnics", "gcloud-list", "gcloud-details", "gcloud-billing"]).describe("Cloud command"),
    },
    async ({ action }) => reply(`vps:${action}`, cco(action)),
  );

  // ── VPS: gh-actions ────────────────────────────────────────
  server.tool(
    "dtk_vps_gha",
    "GitHub Actions: list runs, failures, logs, workflows for cloud/unix/front repos",
    {
      action: z.enum(["runs-cloud", "failed-cloud", "log-cloud", "workflows", "runs-unix", "runs-front"]).describe("GHA command"),
    },
    async ({ action }) => reply(`gha:${action}`, cco(`gha-${action}`)),
  );

  // ── VPS: gh-repos ──────────────────────────────────────────
  server.tool(
    "dtk_vps_gh_repos",
    "GitHub repos: status, list, PRs, issues, recent commits",
    {
      action: z.enum(["status", "list", "prs", "issues", "commits"]).describe("GH repos command"),
    },
    async ({ action }) => {
      const cmd = action === "status" ? "gh-repos-status"
        : action === "list" ? "gh-repos-list"
        : `gh-${action}`;
      return reply(`gh:${action}`, cco(cmd));
    },
  );

  // ── VPS: gh-registry ───────────────────────────────────────
  server.tool(
    "dtk_vps_ghcr",
    "GHCR packages: list, versions, count, inspect, latest tags, visibility",
    {
      action: z.enum(["list", "versions", "count", "inspect", "latest", "visibility"]).describe("GHCR command"),
    },
    async ({ action }) => reply(`ghcr:${action}`, cco(`ghcr-${action}`)),
  );

  // ── SSH ─────────────────────────────────────────────────────
  server.tool(
    "dtk_ssh",
    "Open SSH connection to a VM (interactive — needs TTY)",
    {
      vm: z.enum([...VMS, "github"]).describe("Target VM or github"),
    },
    async ({ vm }) => {
      if (vm === "github") return reply("ssh:github", dtk("21f"));
      const map: Record<string, string> = {
        "gcp-proxy": "21a", "oci-mail": "21b", "oci-analytics": "21c",
        "oci-apps": "21d",
      };
      return reply(`ssh:${vm}`, dtk(map[vm]!));
    },
  );

  // ── mode ────────────────────────────────────────────────────
  server.tool(
    "dtk_mode",
    "Set or check SSH connection mode (ssh=port22, dropbear=port2200, serial=console)",
    {
      mode: z.enum(["ssh", "dropbear", "serial", "status"]).describe("Connection mode to set, or 'status' to check current"),
    },
    async ({ mode }) => reply(`mode:${mode}`, cco(`mode-${mode}`)),
  );
}
