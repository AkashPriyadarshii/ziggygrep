# ziggygrep

## What is this?

A `grep` replacement in pure Zig 0.16.0, no deps, no libc.
Searches files recursively for a literal pattern, prints
`path:lineno:line`. Windows-first; builds for macOS/Linux.

Literal-only in v0.1. Patterns are bytes, not regex.

## Build

```bash
zig build -Doptimize=ReleaseFast
```

Binary lands at `zig-out/bin/ziggygrep` (`ziggygrep.exe` on
Windows). Bench builds use `-Doptimize=ReleaseFast`; size builds
use `-Doptimize=ReleaseSmall`.

## Test

```bash
zig build test
```

Tests live beside the code they cover. Non-trivial logic ships
with one runnable check. Benchmarks vs ripgrep: full table in
README, rerun commands included.

## Flags

| Flag | Long | What it does |
|------|------|-------------|
| `-l` | `--files-with-matches` | Print only names of files with matches |
| `-c` | `--count` | Print match counts per file |
| `-M N` | `--max-columns N` | Truncate lines longer than N columns (`0` disables) |
| `-h` | `--help` | Usage |
| `-V` | `--version` | Version |

## Search architecture (read before editing)

- Literal scan: first-byte prefilter, line bounding with
  backward/forward scans, substring confirm. Short lines
  (`line_len < needle_len`) skipped. Finished lines jumped past
  (`pos = line_end + 1`); a second needle byte on the same line
  can never start a new match line.
- Confirm-first NUL policy: substring confirm runs before the NUL
  check, so non-matching lines pay zero NUL scans. A NUL in a
  matching line suppresses that line.
- Thread pool over files: one file per task, per-thread byte
  arenas, deterministic file-sorted merge. One pool only;
  walk-then-search in sequence, no nested pools.
- Buffered stdout: one lock, one flush. No per-line syscalls.
- No mmap. Streaming reads keep memory flat and work on pipes.

## Exit codes and errors

- 0: match found. 1: no match. 2: usage or I/O error.
- Errors: `ziggygrep: path: reason` on stderr. Dirs skipped
  silently during recursion, reported when named directly.

## Project structure

```
src/
  main.zig    - entry point, error handling, exit codes
  Args.zig    - CLI argument parsing (+ unit tests)
  Walk.zig    - recursive directory walk
  Search.zig  - literal line scan
  Out.zig     - output formatting, buffered writes
build.zig     - Zig build script
build.zig.zon - package metadata
docs/         - PRD, ARCHITECTURE, DESIGN, HANDOFF
memory/       - session notes
```
