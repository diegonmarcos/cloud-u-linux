# tools/0_docs

Documentation for the tools repo.

## Framework

This repo follows the universal declarative workflow framework pattern:

- `0_docs/` — this directory (documentation)
- `9_others/` — GHA + git config management (lightweight engine)
  - `build.sh` — engine entry: build (src/→dist/), deploy (dist/→runtime), test
  - `src/` — source of truth (hooks, scripts, gitconfig, gitignore)
  - `dist/` — generated output, committed, read by git at runtime

To rebuild: `./9_others/build.sh`
