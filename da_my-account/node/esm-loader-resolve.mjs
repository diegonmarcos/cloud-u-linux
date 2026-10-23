// ESM resolve hook — adds NODE_PATH directories to ESM package resolution
// Intercepts bare specifiers that fail default resolution, then searches
// NODE_PATH directories (colon-separated, same as CJS convention).
import { existsSync, readFileSync } from "node:fs";
import { join, sep } from "node:path";
import { pathToFileURL } from "node:url";

const NODE_PATHS = (process.env.NODE_PATH || "")
  .split(":")
  .filter(Boolean);

// Resolve package.json exports map for a subpath import
function resolveExports(pkgDir, subpath) {
  const pkgPath = join(pkgDir, "package.json");
  if (!existsSync(pkgPath)) return null;

  const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
  const exports = pkg.exports;
  if (!exports) {
    // No exports map — try direct file resolution
    const direct = join(pkgDir, subpath);
    return existsSync(direct) ? direct : null;
  }

  // Try exact subpath match: "./server/mcp.js"
  const subKey = "./" + subpath;
  const entry = exports[subKey];
  if (entry) {
    const target = typeof entry === "string" ? entry : entry.import || entry.default;
    if (target) {
      const resolved = join(pkgDir, target);
      return existsSync(resolved) ? resolved : null;
    }
  }

  // Try wildcard exports: "./*" -> "./dist/esm/*"
  for (const [pattern, mapping] of Object.entries(exports)) {
    if (!pattern.includes("*")) continue;
    const regex = new RegExp("^" + pattern.replace("*", "(.+)") + "$");
    const match = subKey.match(regex);
    if (match) {
      const target = typeof mapping === "string" ? mapping : mapping.import || mapping.default;
      if (target) {
        const resolved = join(pkgDir, target.replace("*", match[1]));
        return existsSync(resolved) ? resolved : null;
      }
    }
  }

  return null;
}

export async function resolve(specifier, context, nextResolve) {
  // Only intercept bare specifiers (not relative, absolute, or URLs)
  if (
    specifier.startsWith(".") ||
    specifier.startsWith("/") ||
    specifier.startsWith("file:") ||
    specifier.startsWith("node:") ||
    specifier.startsWith("data:")
  ) {
    return nextResolve(specifier, context);
  }

  // Try default resolution first
  try {
    return await nextResolve(specifier, context);
  } catch (err) {
    if (err.code !== "ERR_MODULE_NOT_FOUND" || NODE_PATHS.length === 0) {
      throw err;
    }

    // Parse scoped/unscoped package name + subpath
    const parts = specifier.split("/");
    let pkgName, subpath;
    if (specifier.startsWith("@")) {
      pkgName = parts.slice(0, 2).join("/");
      subpath = parts.slice(2).join("/");
    } else {
      pkgName = parts[0];
      subpath = parts.slice(1).join("/");
    }

    for (const dir of NODE_PATHS) {
      const pkgDir = join(dir, pkgName);
      if (!existsSync(pkgDir)) continue;

      if (!subpath) {
        // Root import — resolve via exports "." or main
        const pkgPath = join(pkgDir, "package.json");
        if (existsSync(pkgPath)) {
          const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
          const main = pkg.exports?.["."]?.import || pkg.exports?.["."]?.default ||
                       (typeof pkg.exports?.["."] === "string" ? pkg.exports["."] : null) ||
                       pkg.module || pkg.main || "index.js";
          const resolved = join(pkgDir, main);
          if (existsSync(resolved)) {
            return { url: pathToFileURL(resolved).href, shortCircuit: true };
          }
        }
      } else {
        // Subpath import — resolve via exports map
        const resolved = resolveExports(pkgDir, subpath);
        if (resolved) {
          return { url: pathToFileURL(resolved).href, shortCircuit: true };
        }

        // Fallback: direct file
        const direct = join(pkgDir, subpath);
        if (existsSync(direct)) {
          return { url: pathToFileURL(direct).href, shortCircuit: true };
        }
      }
    }

    throw err;
  }
}
