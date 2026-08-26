import { existsSync } from "fs";
import { join } from "path";

const HOME = process.env.HOME ?? "/home/diego";

// Detect platform
const IS_TERMUX = existsSync("/data/data/com.termux.nix");

// ~/git is the standard path on all platforms (symlink on desktop → ~/Mounts/Git)
export const GIT_ROOT = join(HOME, "git");

export const UNIX_ROOT = join(GIT_ROOT, "unix");
export const CLOUD_ROOT = join(GIT_ROOT, "cloud");

export const FLAKE_TERMUX = join(UNIX_ROOT, "bb_flakes_termux");
export const FLAKE_DESKTOP = join(UNIX_ROOT, "ba_flakes_desktop");
export const FLAKE_HOST = join(UNIX_ROOT, "aa_nixos-surface_host");
export const CLOUD_HM = join(CLOUD_ROOT, "b_infra");
export const CLOUD_DATA = join(HOME, "git/cloud-data");

export const PLATFORM = IS_TERMUX ? "termux" : "desktop";

export const CLOUD_VMS = [
  "gcp-proxy", "gcp-t4", "oci-mail", "oci-analytics", "oci-apps", "oci-apps-2",
];
