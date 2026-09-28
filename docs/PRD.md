# ziggygrep PRD

## Problem

Recursive code search pays full scan cost on every query. The
fast tools either need an index plus a daemon (tgrep, instant-grep
variants) or carry a regex engine through literal queries. Most
daily searches are literal bytes (`HashMap`, `TODO`, `fn main`).

## Product

One static Zig binary. Literal pattern in, `path:lineno:line`
out. No index, no daemon, no regex engine, no config.

## Users

Developers and terminal users who search code daily. CI jobs
that need a fast literal sweep without installing a toolchain.

## v0.1 scope

- Literal substring search, byte-exact.
- Recursive directory walk. Skips dotfiles and `.git`.
- Flags: `-l`, `-c`, `-M N`, `-h`, `-V`.
- Exit codes: 0 match, 1 no match, 2 error.
- `zig build test` green. Benchmark table with rerun commands.

## Non-goals (v0.1)

- Regex, case-insensitive, word match, invert, context lines.
- `.gitignore` parsing. Colors. JSON output. Paging.
- Index, daemon, background services, mmap.
- Binary-file detection beyond NUL-suppresses-matching-line.

## Success criteria

- Correct: line-level parity with `rg -F` on clean corpora.
- Fast: median wall time at or below ripgrep on the bench corpus.
- Small: one binary, zero deps, builds on Windows/macOS/Linux.
