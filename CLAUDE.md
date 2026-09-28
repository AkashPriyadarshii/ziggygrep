# ziggygrep

## What is this?

A `grep` replacement in pure Zig 0.16.0, no deps, no libc.
Literal search, recursive walk, threaded file sweep.

## Build

```bash
zig build -Doptimize=ReleaseFast
```

## Test

```bash
zig build test
```

## Flags

`-l` files-with-matches, `-c` count, `-M N` max-columns
(`0` disables), `-h` help, `-V` version.

## Architecture

- Literal scan only: prefilter, bound, confirm. See AGENTS.md.
- Thread pool over files, per-thread arenas, sorted merge.
- Buffered stdout, one flush. No mmap.

## Project structure

```
src/
  main.zig    - entry point, error handling
  Args.zig    - CLI argument parsing (+ unit tests)
  Walk.zig    - recursive directory walk
  Search.zig  - literal line scan
  Out.zig     - output formatting, buffered writes
```
