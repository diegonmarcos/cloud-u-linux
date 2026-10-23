// ESM NODE_PATH loader — registers resolve hook that makes ESM honor NODE_PATH
// Node.js ESM ignores NODE_PATH by design. This loader restores that behavior
// using the stable module.register() API (Node 20.6+).
import { register } from "node:module";
register("./esm-loader-resolve.mjs", import.meta.url);
