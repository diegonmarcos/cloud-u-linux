import { spawnSync } from "child_process";

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  ok: boolean;
}

export function exec(
  command: string,
  args: string[],
  options?: { timeout?: number; cwd?: string; input?: string; env?: Record<string, string> }
): ExecResult {
  const timeout = options?.timeout ?? 30_000;
  const result = spawnSync(command, args, {
    timeout,
    cwd: options?.cwd,
    encoding: "utf-8",
    env: options?.env ? { ...process.env, ...options.env } : process.env,
    maxBuffer: 10 * 1024 * 1024,
    ...(options?.input !== undefined ? { input: options.input } : {}),
  });

  return {
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    exitCode: result.status ?? 1,
    ok: result.status === 0,
  };
}

export function sh(script: string, options?: { timeout?: number; cwd?: string }): ExecResult {
  return exec("sh", ["-c", script], options);
}

export function formatResult(label: string, result: ExecResult): string {
  const lines = [
    `${label}: ${result.ok ? "OK" : "FAILED"} (exit ${result.exitCode})`,
  ];
  if (result.stdout) lines.push(result.stdout.slice(-4000));
  if (result.stderr && !result.ok) lines.push(`--- stderr ---\n${result.stderr.slice(-1000)}`);
  return lines.join("\n");
}
