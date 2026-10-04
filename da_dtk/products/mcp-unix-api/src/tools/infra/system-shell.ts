// A) Infra-Dev — System & Shell
// Merged: system.ts + shell.ts + shell-config.ts
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { sh, formatResult } from "../../exec.js";
import { PLATFORM, UNIX_ROOT } from "../../paths.js";

const SHELLS_DIR = join(UNIX_ROOT, "bb_flakes_termux/src/modules/programs/shells");
const MODULES_DIR = join(UNIX_ROOT, "bb_flakes_termux/src/modules");

const SHELL_FILES: Record<string, string> = {
  "fish": join(SHELLS_DIR, "fish.nix"),
  "fish-greeting": join(SHELLS_DIR, "fish-greeting.nix"),
  "bash": join(SHELLS_DIR, "bash.nix"),
  "starship": join(SHELLS_DIR, "starship.nix"),
  "guardrails": join(MODULES_DIR, "guardrails.nix"),
};

function readNixFile(key: string): string {
  const path = SHELL_FILES[key];
  if (!path || !existsSync(path)) return `File not found: ${key}`;
  return readFileSync(path, "utf-8");
}

function parseNixAttrs(content: string, blockName: string): Record<string, string> {
  const result: Record<string, string> = {};
  const re = new RegExp(`${blockName}\\s*=\\s*\\{([^}]+)\\}`, "s");
  const match = content.match(re);
  if (!match) return result;
  const block = match[1];
  const lines = block.matchAll(/^\s*(?:"([^"]+)"|(\w+))\s*=\s*"([^"]+)"/gm);
  for (const m of lines) {
    const key = m[1] ?? m[2];
    result[key] = m[3];
  }
  return result;
}

function parseNixFunctions(content: string): Record<string, string> {
  const result: Record<string, string> = {};
  const oneLiners = content.matchAll(/^\s{6}(\w+)\s*=\s*"([^"]+)"/gm);
  for (const m of oneLiners) {
    result[m[1]] = m[2];
  }
  const multiLine = content.matchAll(/^\s{6}(\w+)\s*=\s*''([\s\S]*?)''/gm);
  for (const m of multiLine) {
    result[m[1]] = m[2].trim();
  }
  return result;
}

export function registerSystemShellTools(server: McpServer) {
  // ═══ System (5 tools) ═══

  server.tool(
    "infra.sys.info",
    "Show system information (platform, kernel, memory, disk, nix version)",
    {},
    async () => {
      const result = sh(`
        echo "platform: ${PLATFORM}"
        echo "kernel: $(uname -r)"
        echo "arch: $(uname -m)"
        echo "nix: $(nix --version 2>/dev/null || echo 'not found')"
        echo "node: $(node --version 2>/dev/null || echo 'not found')"
        echo ""
        echo "--- memory ---"
        free -h 2>/dev/null || echo "free not available"
        echo ""
        echo "--- disk ---"
        df -h / $HOME 2>/dev/null | head -5
      `);
      return { content: [{ type: "text", text: result.stdout }] };
    }
  );

  server.tool(
    "infra.sys.env",
    "Show relevant environment variables (PATH, NIX, NODE, SHELL)",
    {},
    async () => {
      const result = sh(`
        for var in PATH SHELL HOME USER NODE_PATH NIX_PATH LD_PRELOAD PLATFORM; do
          val="$(printenv "$var" 2>/dev/null || echo '<unset>')"
          printf "%-15s %s\n" "$var" "$val"
        done
      `);
      return { content: [{ type: "text", text: result.stdout }] };
    }
  );

  server.tool(
    "infra.sys.which",
    "Check if tools are available and show their paths (uses command -v)",
    {
      tools: z.string().describe("Space-separated list of tool names (e.g. 'git nix jq curl')"),
    },
    async ({ tools }) => {
      const result = sh(`
        for t in ${tools}; do
          path="$(command -v "$t" 2>/dev/null)"
          if [ -n "$path" ]; then
            printf "%-20s %s\n" "$t" "$path"
          else
            printf "%-20s NOT FOUND\n" "$t"
          fi
        done
      `);
      return { content: [{ type: "text", text: result.stdout }] };
    }
  );

  server.tool(
    "infra.sys.processes",
    "Show running processes (filtered by optional pattern)",
    {
      pattern: z.string().optional().describe("Grep pattern to filter processes"),
    },
    async ({ pattern }) => {
      const cmd = pattern
        ? `ps aux 2>/dev/null | head -1; ps aux 2>/dev/null | grep -i "${pattern}" | grep -v grep | head -30`
        : `ps aux 2>/dev/null | head -20`;
      const result = sh(cmd);
      return { content: [{ type: "text", text: result.stdout || "No processes found" }] };
    }
  );

  server.tool(
    "infra.sys.packages",
    "List nix-profile installed packages",
    {},
    async () => {
      const result = sh(`nix-env -q 2>/dev/null || ls ~/.nix-profile/bin/ 2>/dev/null | sort`);
      return {
        content: [{ type: "text", text: result.ok ? result.stdout : formatResult("packages", result) }],
        isError: !result.ok,
      };
    }
  );

  // ═══ Shell execution (3 tools) ═══

  server.tool(
    "infra.shell.exec",
    "Execute a shell command and return output (30s timeout, use with care)",
    {
      command: z.string().describe("Shell command to execute"),
      timeout: z.number().optional().describe("Timeout in ms (default: 30000, max: 300000)"),
      cwd: z.string().optional().describe("Working directory"),
    },
    async ({ command, timeout, cwd }) => {
      const ms = Math.min(timeout ?? 30_000, 300_000);
      const result = sh(command, { timeout: ms, cwd });
      return {
        content: [{ type: "text", text: formatResult("shell", result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "infra.shell.npm_list",
    "List globally installed npm packages",
    {},
    async () => {
      const result = sh(`npm list -g --depth=0 2>/dev/null`);
      return { content: [{ type: "text", text: result.stdout || "No global packages" }] };
    }
  );

  server.tool(
    "infra.shell.npm_install",
    "Install or update a global npm package",
    {
      package: z.string().describe("Package name (e.g. @anthropic-ai/claude-code@latest)"),
    },
    async ({ package: pkg }) => {
      const result = sh(`npm install -g "${pkg}" 2>&1`, { timeout: 120_000 });
      return {
        content: [{ type: "text", text: formatResult(`npm -g install ${pkg}`, result) }],
        isError: !result.ok,
      };
    }
  );

  // ═══ Shell config (7 tools) ═══

  server.tool(
    "infra.shell.aliases",
    "List all shell aliases (fish and bash) from nix config",
    {
      shell: z.enum(["fish", "bash", "both"]).optional().describe("Which shell (default: both)"),
    },
    async ({ shell }) => {
      const lines: string[] = [];

      if (shell !== "bash") {
        const fishContent = readNixFile("fish");
        const fishAliases = parseNixAttrs(fishContent, "shellAliases");
        const fishAbbrs = parseNixAttrs(fishContent, "shellAbbrs");
        lines.push("=== Fish Aliases ===");
        for (const [k, v] of Object.entries(fishAliases)) {
          lines.push(`  ${k.padEnd(12)} → ${v}`);
        }
        lines.push("\n=== Fish Abbreviations ===");
        for (const [k, v] of Object.entries(fishAbbrs)) {
          lines.push(`  ${k.padEnd(12)} → ${v}`);
        }
      }

      if (shell !== "fish") {
        const bashContent = readNixFile("bash");
        const bashAliases = parseNixAttrs(bashContent, "shellAliases");
        lines.push("\n=== Bash Aliases ===");
        for (const [k, v] of Object.entries(bashAliases)) {
          lines.push(`  ${k.padEnd(12)} → ${v}`);
        }
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  server.tool(
    "infra.shell.functions",
    "List all custom shell functions from nix config",
    {
      shell: z.enum(["fish", "bash", "both"]).optional().describe("Which shell (default: both)"),
    },
    async ({ shell }) => {
      const lines: string[] = [];

      if (shell !== "bash") {
        const fishContent = readNixFile("fish");
        const fishFns = parseNixFunctions(fishContent);
        lines.push("=== Fish Functions ===");
        for (const [name, body] of Object.entries(fishFns)) {
          const preview = body.split("\n")[0].slice(0, 60);
          lines.push(`  ${name.padEnd(14)} ${preview}${body.includes("\n") ? " ..." : ""}`);
        }
      }

      if (shell !== "fish") {
        lines.push("\n=== Bash Functions (in initExtra) ===");
        const bashContent = readNixFile("bash");
        const fnMatches = bashContent.matchAll(/^\s{6}(\w+)\(\)\s*\{/gm);
        for (const m of fnMatches) {
          lines.push(`  ${m[1]}`);
        }
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  server.tool(
    "infra.shell.read_config",
    "Read the full nix source for a shell config file",
    {
      file: z.enum(["fish", "fish-greeting", "bash", "starship", "guardrails"])
        .describe("Which config file to read"),
    },
    async ({ file }) => {
      const content = readNixFile(file);
      const path = SHELL_FILES[file];
      return {
        content: [{ type: "text", text: `# ${path}\n\n${content}` }],
      };
    }
  );

  server.tool(
    "infra.shell.greeting",
    "Show the current fish greeting / welcome screen (runs it live)",
    {},
    async () => {
      const result = sh(`fish -c "fish_greeting" 2>&1`, { timeout: 10_000 });
      return {
        content: [{ type: "text", text: result.stdout || result.stderr || "No output" }],
      };
    }
  );

  server.tool(
    "infra.shell.starship",
    "Show parsed starship prompt configuration (format, modules, symbols)",
    {},
    async () => {
      const content = readNixFile("starship");
      const lines: string[] = ["=== Starship Prompt Configuration ===\n"];

      const fmtMatch = content.match(/format\s*=\s*lib\.concatStrings\s*\[([\s\S]*?)\]/);
      if (fmtMatch) {
        const segments = fmtMatch[1].matchAll(/"([^"]+)"/g);
        lines.push("Prompt format:");
        for (const s of segments) {
          lines.push(`  ${s[1]}`);
        }
        lines.push("");
      }

      const modules = content.matchAll(/^\s{6}(\w+)\s*=\s*\{([\s\S]*?)\};/gm);
      for (const m of modules) {
        const name = m[1];
        const body = m[2];
        const symbol = body.match(/symbol\s*=\s*"([^"]+)"/)?.[1] ?? "";
        const format = body.match(/format\s*=\s*"([^"]+)"/)?.[1] ?? "";
        if (symbol || format) {
          lines.push(`${name}: symbol="${symbol}" format="${format}"`);
        }
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  server.tool(
    "infra.shell.guardrails",
    "Show guardrail tiers: which commands are whitelisted, blocked, confirm, or warning",
    {},
    async () => {
      const content = readNixFile("guardrails");
      const lines: string[] = ["=== Guardrail Tiers ===\n"];

      lines.push("TIER 0 — WHITELIST (pass through):");
      const wlMatches = content.matchAll(/\{ cmd = "(\w+)"; subcommands = \[([\s\S]*?)\]/g);
      for (const m of wlMatches) {
        const subs = m[2].match(/"([^"]+)"/g)?.map(s => s.replace(/"/g, "")).join(", ") ?? "";
        lines.push(`  ${m[1].padEnd(16)} ${subs}`);
      }

      lines.push("\nTIER 1 — BLOCKED (hard stop):");
      const blMatches = content.matchAll(/\{ cmd = "([^"]+)";\s*match = "([^"]+)";\s*reason = "([^"]+)"/g);
      for (const m of blMatches) {
        lines.push(`  ${m[1]} ${m[2].padEnd(30)} ${m[3]}`);
      }

      lines.push("\nTIER 2 — CONFIRM (ask y/N):");
      const cfMatch = content.match(/confirmCmds\s*=\s*\[([\s\S]*?)\]/);
      if (cfMatch) {
        const cmds = cfMatch[1].match(/"([^"]+)"/g)?.map(s => s.replace(/"/g, "")) ?? [];
        lines.push(`  ${cmds.join(", ")}`);
      }

      lines.push("\nTIER 3 — WARNING (banner then run):");
      const wrMatch = content.match(/warningCmds\s*=\s*\[([\s\S]*?)\]/);
      if (wrMatch) {
        const cmds = wrMatch[1].match(/"([^"]+)"/g)?.map(s => s.replace(/"/g, "")) ?? [];
        lines.push(`  ${cmds.join(", ")}`);
      }

      return { content: [{ type: "text", text: lines.join("\n") }] };
    }
  );

  server.tool(
    "infra.shell.active_aliases",
    "Show currently active aliases in fish or bash (live from running shell)",
    {
      shell: z.enum(["fish", "bash"]).optional().describe("Which shell (default: fish)"),
    },
    async ({ shell }) => {
      const cmd = (shell ?? "fish") === "fish"
        ? `fish -c "alias" 2>&1 | head -50`
        : `sh -c '. ~/.bashrc 2>/dev/null; alias' 2>&1 | head -50`;
      const result = sh(cmd, { timeout: 10_000 });
      return {
        content: [{ type: "text", text: result.stdout || result.stderr || "No aliases" }],
      };
    }
  );
}
