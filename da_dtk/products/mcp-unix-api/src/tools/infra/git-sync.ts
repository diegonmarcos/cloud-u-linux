// A) Infra-Dev — Git (multi-repo sync + standalone git operations)
// Merged: git.ts + connect_git_sync + connect_gacp from scripts.ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { sh, formatResult } from "../../exec.js";
import { GIT_ROOT } from "../../paths.js";

const REPOS = ["unix", "cloud", "front", "vault", "tools"];

export function registerGitSyncTools(server: McpServer) {
  // ═══ Connect: git sync (2 tools) ═══

  server.tool(
    "infra.git.sync",
    "Sync all git repos (commit + pull + push)",
    {
      action: z.enum(["sync", "pull", "push", "commit", "fetch", "fetch-status", "dirty", "git-refresh"])
        .optional().describe("Git action (default: sync)"),
    },
    async ({ action }) => {
      const cmd = action ?? "sync";
      const result = sh(`connect ${cmd} 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult(`connect ${cmd}`, result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "infra.git.gacp",
    "Git add, commit, and push all repos (convenience wrapper)",
    {
      message: z.string().optional().describe("Commit message (default: auto-generated)"),
    },
    async ({ message }) => {
      const args = message ? `"${message}"` : "";
      const result = sh(`gacp ${args} 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult("gacp", result) }],
        isError: !result.ok,
      };
    }
  );

  // ═══ Standalone git operations (4 tools) ═══

  server.tool(
    "infra.git.status_all",
    "Show git status across all tracked repos (unix, cloud, front, vault, tools)",
    {},
    async () => {
      const lines: string[] = [];
      for (const repo of REPOS) {
        const result = sh(
          `cd "${GIT_ROOT}/${repo}" 2>/dev/null && echo "=== ${repo} ($(git branch --show-current)) ===" && git status -s | head -20 || echo "=== ${repo}: not found ==="`,
          { timeout: 10_000 }
        );
        lines.push(result.stdout.trim());
      }
      return { content: [{ type: "text", text: lines.join("\n\n") }] };
    }
  );

  server.tool(
    "infra.git.log",
    "Show recent git log for a repo",
    {
      repo: z.enum(["unix", "cloud", "front", "vault", "tools"]).describe("Repository name"),
      count: z.number().optional().describe("Number of commits (default: 10)"),
    },
    async ({ repo, count }) => {
      const n = count ?? 10;
      const result = sh(
        `git -C "${GIT_ROOT}/${repo}" log --oneline -${n} 2>&1`,
        { timeout: 10_000 }
      );
      return {
        content: [{ type: "text", text: result.ok ? result.stdout : formatResult("git log", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "infra.git.diff",
    "Show git diff for a repo (staged or unstaged)",
    {
      repo: z.enum(["unix", "cloud", "front", "vault", "tools"]).describe("Repository name"),
      staged: z.boolean().optional().describe("Show staged changes (default: false)"),
    },
    async ({ repo, staged }) => {
      const flag = staged ? "--cached" : "";
      const result = sh(
        `git -C "${GIT_ROOT}/${repo}" diff ${flag} 2>&1 | head -200`,
        { timeout: 10_000 }
      );
      return {
        content: [{ type: "text", text: result.ok ? (result.stdout || "No changes") : formatResult("git diff", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "infra.git.remote_status",
    "Check if repos are ahead/behind their remote",
    {},
    async () => {
      const lines: string[] = [];
      for (const repo of REPOS) {
        const result = sh(
          `cd "${GIT_ROOT}/${repo}" 2>/dev/null && git fetch --dry-run 2>&1; echo "$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo '? ?')" | awk '{print "'${repo}': ahead="$1" behind="$2}'`,
          { timeout: 15_000 }
        );
        lines.push(result.stdout.trim());
      }
      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );
}
