// B) User-Services — Email (IMAP/SMTP access via openssl s_client)
// Credentials auto-loaded from cloud-data/secrets; no secrets in this repo.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { readFileSync } from "fs";
import { join } from "path";
import { exec, sh, formatResult } from "../../exec.js";
import { CLOUD_DATA } from "../../paths.js";

const MAIL_SECRETS_PATH = join(
  CLOUD_DATA,
  "secrets/aa-sui_tools-maddy-secrets.json.secrets"
);
const DEFAULT_IMAP_HOST = process.env.IMAP_HOST ?? "mail.diegonmarcos.com";
const DEFAULT_SMTP_HOST = process.env.SMTP_HOST ?? "mail.diegonmarcos.com";
const DEFAULT_PORT_IMAP = 993;
const DEFAULT_PORT_SMTP = 465;

function loadMailSecrets(): { user: string; pass: string } | null {
  try {
    const raw = readFileSync(MAIL_SECRETS_PATH, "utf-8");
    const data = JSON.parse(raw);
    if (data.MAIL_USER && data.MAIL_PASSWORD) {
      return { user: data.MAIL_USER, pass: data.MAIL_PASSWORD };
    }
    return null;
  } catch {
    return null;
  }
}

function imapExec(
  host: string,
  port: number,
  user: string,
  pass: string,
  commands: string[],
  timeoutMs = 20_000
) {
  // Use bash coprocess for proper IMAP command sequencing.
  // Each command waits for its tagged response before sending the next.
  const tags = commands.map((_, i) => `A${String(i + 2).padStart(3, "0")}`);
  const escapedCmds = commands
    .map((c, i) => {
      const escaped = c.replace(/'/g, "'\\''");
      // Strip any user-provided tag prefix — we use our own tags
      const body = escaped.replace(/^[A-Z]\d+\s+/, "");
      return [
        `echo '${tags[i]} ${body}' >&\${COPROC[1]}`,
        `while IFS= read -r -t 5 line; do printf '%s\\n' "$line"; [[ "$line" == "${tags[i]} "* ]] && break; done <&\${COPROC[0]}`,
      ].join("\n");
    })
    .join("\n");

  const script = `
coproc openssl s_client -connect ${host}:${port} -quiet -crlf 2>/dev/null

# Wait for server greeting (OK line)
while IFS= read -r -t 3 line; do printf '%s\\n' "$line"; [[ "$line" == *OK* ]] && break; done <&\${COPROC[0]}

# LOGIN — wait for A001 response
echo "A001 LOGIN $IMAP_U $IMAP_P" >&\${COPROC[1]}
while IFS= read -r -t 5 line; do printf '%s\\n' "$line"; [[ "$line" == "A001 "* ]] && break; done <&\${COPROC[0]}

# Post-login commands
${escapedCmds}

# LOGOUT
echo 'Z000 LOGOUT' >&\${COPROC[1]}
while IFS= read -r -t 2 line; do printf '%s\\n' "$line"; [[ "$line" == "Z000 "* ]] && break; done <&\${COPROC[0]}
`;

  const result = exec("bash", ["-c", script], {
    timeout: timeoutMs,
    env: { IMAP_U: user, IMAP_P: pass },
  });
  const authOk = result.stdout.includes("A001 OK") || result.stdout.includes("Authentication successful");
  return { ...result, ok: authOk || result.ok };
}

function resolveCredentials(
  userParam?: string,
  passParam?: string
): { user: string; pass: string } | null {
  if (userParam && passParam) return { user: userParam, pass: passParam };
  const secrets = loadMailSecrets();
  if (!secrets) return null;
  return {
    user: userParam ?? secrets.user,
    pass: passParam ?? secrets.pass,
  };
}

export function registerEmailTools(server: McpServer) {
  server.tool(
    "services.email.imap_fetch",
    "Fetch recent emails from an IMAP mailbox via openssl s_client (SSL/TLS). Returns headers (From, Subject, Date) for the N most recent messages. Credentials auto-loaded from cloud-data secrets.",
    {
      user: z.string().optional().describe("IMAP username (auto-loaded from secrets if omitted)"),
      pass: z.string().optional().describe("IMAP password (auto-loaded from secrets if omitted)"),
      host: z.string().optional().describe(`IMAP host (default: ${DEFAULT_IMAP_HOST})`),
      port: z.number().optional().describe(`IMAP port (default: ${DEFAULT_PORT_IMAP})`),
      mailbox: z.string().optional().describe("Mailbox to open (default: INBOX)"),
      count: z.number().optional().describe("Number of recent messages to fetch (default: 10, max: 50)"),
    },
    async ({ user, pass, host, port, mailbox, count }) => {
      const creds = resolveCredentials(user, pass);
      if (!creds)
        return {
          content: [{ type: "text", text: "No credentials: provide user/pass or ensure cloud-data secrets exist" }],
          isError: true,
        };

      const h = host ?? DEFAULT_IMAP_HOST;
      const p = port ?? DEFAULT_PORT_IMAP;
      const mb = mailbox ?? "INBOX";
      const n = Math.min(count ?? 10, 50);

      const cmds = [
        `A002 SELECT "${mb}"`,
        `A003 FETCH 1:${n} (FLAGS BODY[HEADER.FIELDS (FROM TO SUBJECT DATE)])`,
      ];

      const result = imapExec(h, p, creds.user, creds.pass, cmds, 20_000);
      return {
        content: [{ type: "text", text: formatResult(`imap:fetch(${h})`, result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "services.email.imap_list",
    "List all mailboxes/folders on an IMAP server via openssl s_client. Credentials auto-loaded from cloud-data secrets.",
    {
      user: z.string().optional().describe("IMAP username (auto-loaded from secrets if omitted)"),
      pass: z.string().optional().describe("IMAP password (auto-loaded from secrets if omitted)"),
      host: z.string().optional().describe(`IMAP host (default: ${DEFAULT_IMAP_HOST})`),
      port: z.number().optional().describe(`IMAP port (default: ${DEFAULT_PORT_IMAP})`),
    },
    async ({ user, pass, host, port }) => {
      const creds = resolveCredentials(user, pass);
      if (!creds)
        return {
          content: [{ type: "text", text: "No credentials: provide user/pass or ensure cloud-data secrets exist" }],
          isError: true,
        };

      const h = host ?? DEFAULT_IMAP_HOST;
      const p = port ?? DEFAULT_PORT_IMAP;

      const result = imapExec(h, p, creds.user, creds.pass, [`A002 LIST "" "*"`], 15_000);
      return {
        content: [{ type: "text", text: formatResult(`imap:list(${h})`, result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "services.email.imap_raw",
    "Send raw IMAP commands to a server via openssl s_client. Login is handled automatically; provide only post-login commands. Credentials auto-loaded from cloud-data secrets.",
    {
      commands: z.array(z.string()).describe("IMAP commands to run after login (e.g. ['A002 SELECT INBOX', 'A003 SEARCH UNSEEN'])"),
      user: z.string().optional().describe("IMAP username (auto-loaded from secrets if omitted)"),
      pass: z.string().optional().describe("IMAP password (auto-loaded from secrets if omitted)"),
      host: z.string().optional().describe(`IMAP host (default: ${DEFAULT_IMAP_HOST})`),
      port: z.number().optional().describe(`IMAP port (default: ${DEFAULT_PORT_IMAP})`),
    },
    async ({ commands, user, pass, host, port }) => {
      const creds = resolveCredentials(user, pass);
      if (!creds)
        return {
          content: [{ type: "text", text: "No credentials: provide user/pass or ensure cloud-data secrets exist" }],
          isError: true,
        };

      const h = host ?? DEFAULT_IMAP_HOST;
      const p = port ?? DEFAULT_PORT_IMAP;

      const result = imapExec(h, p, creds.user, creds.pass, commands, 30_000);
      return {
        content: [{ type: "text", text: formatResult(`imap:raw(${h})`, result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "services.email.cert_check",
    "Inspect the SSL/TLS certificate of a mail server (IMAP or SMTP) using openssl s_client.",
    {
      host: z.string().optional().describe(`Mail host to check (default: ${DEFAULT_IMAP_HOST})`),
      port: z.number().optional().describe(`Port to connect to (default: ${DEFAULT_PORT_IMAP} for IMAP)`),
      protocol: z.enum(["imap", "smtp"]).optional().describe("Protocol hint — affects starttls mode (default: imap)"),
    },
    async ({ host, port, protocol }) => {
      const proto = protocol ?? "imap";
      const h = host ?? (proto === "smtp" ? DEFAULT_SMTP_HOST : DEFAULT_IMAP_HOST);
      const p = port ?? (proto === "smtp" ? DEFAULT_PORT_SMTP : DEFAULT_PORT_IMAP);

      const starttls = proto === "smtp" && p !== 465 ? "-starttls smtp" : "";
      const cmd = `echo Q | openssl s_client -connect ${h}:${p} ${starttls} -showcerts 2>&1 | openssl x509 -noout -text 2>/dev/null | grep -E '(Subject|Issuer|Not Before|Not After|DNS:|IP Address)' | head -40`;
      const result = sh(cmd, { timeout: 15_000 });
      return {
        content: [{ type: "text", text: formatResult(`cert:${h}:${p}`, result) }],
        isError: !result.ok,
      };
    }
  );

  server.tool(
    "services.email.smtp_test",
    "Test SMTP server connectivity and TLS handshake via openssl s_client. Does NOT send mail.",
    {
      host: z.string().optional().describe(`SMTP host (default: ${DEFAULT_SMTP_HOST})`),
      port: z.number().optional().describe(`SMTP port (default: ${DEFAULT_PORT_SMTP})`),
    },
    async ({ host, port }) => {
      const h = host ?? DEFAULT_SMTP_HOST;
      const p = port ?? DEFAULT_PORT_SMTP;
      const starttls = p === 587 || p === 25 ? "-starttls smtp" : "";
      const cmd = `echo QUIT | openssl s_client -connect ${h}:${p} ${starttls} -quiet 2>&1 | head -30`;
      const result = sh(cmd, { timeout: 15_000 });
      return {
        content: [{ type: "text", text: formatResult(`smtp:test(${h}:${p})`, result) }],
        isError: !result.ok,
      };
    }
  );
}
