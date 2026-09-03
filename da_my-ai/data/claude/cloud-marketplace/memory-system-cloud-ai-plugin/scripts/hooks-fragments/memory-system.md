# Memory System — Structure Rule

`MEMORY.md` is an **index** for Claude to decide what to read. It is NOT a preload bundle.
Entry files must never be auto-loaded — reading one is a per-task decision, via the Read tool.

## Measured behavior (2026-07-30) — do not "improve" this layout

Claude Code auto-loads `MEMORY.md` **plus any `.md` under subdirectories of the memory dir**.
Loose `.md` files sitting beside `MEMORY.md` are not auto-loaded, but subdirectories ARE walked.

A reorg into `memory/{feedback,project,reference,user}/` therefore turned 129 entry files into
auto-loaded imports: session preload jumped **~4.5k → ~87k tokens** (350,661 chars). An earlier
version of this very fragment recommended a `memory/entries/` subfolder — that advice was
**backwards** and caused the blowup. It is corrected here.

## MANDATORY layout

```
~/.claude/projects/<project>/
├── memory/
│   └── MEMORY.md          ← the ONLY file here; auto-loaded every session
└── memory-entries/        ← OUTSIDE memory/ ⇒ can never be auto-loaded
    ├── feedback/
    ├── project/
    ├── reference/
    └── user/
```

- **ALWAYS** write a new entry to `memory-entries/<type>/<name>.md` — never inside `memory/`
- **ALWAYS** add a one-line pointer in `MEMORY.md` linking to `../memory-entries/<type>/<name>.md`
- `memory/` must contain **only** `MEMORY.md` — no loose files, no subdirectories, ever
- Keep `MEMORY.md` itself lean; it is paid for on every single session

## Reading memory

`MEMORY.md` is already in context. Scan it, then Read `../memory-entries/<type>/<name>.md` only
when that specific entry matters for the task at hand.
