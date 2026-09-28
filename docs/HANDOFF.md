# ziggygrep HANDOFF

## Status

Skeleton only. No source files yet. Docs define v0.1 scope.

## Next steps

1. `build.zig` + `build.zig.zon` (Zig 0.16.0, exe `ziggygrep`).
2. `src/Args.zig` with parser + unit tests.
3. `src/Search.zig` line scan, port the proven algorithm:
   first-byte prefilter, line bounding, short-line skip,
   jump-past-line, confirm-first NUL check.
4. `src/Walk.zig` recursive walk, skip dotfiles + `.git`.
5. `src/Out.zig` formatting + buffered writes.
6. `src/main.zig` wiring, thread pool, exit codes.
7. Bench vs ripgrep on a fixed corpus, medians + rerun table.

## Proven algorithm (from rustygrep `line_spans`)

- `memchr` first needle byte from `pos`.
- Bound the line: backward scan for `\n`, forward scan for `\n`.
- Skip lines shorter than the needle.
- Confirm with substring search, then NUL check (confirm first,
  so clean non-matching lines pay zero NUL scans).
- Jump `pos` past line end either way.
- Track line numbers by counting `\n` crossed between
  consecutive candidate lines.

## Open questions

- Default thread count: pool size heuristic vs fixed.
- `.gitignore` support: full parser or glob subset post-v0.1.
- Binary files: keep line-suppress or adopt whole-file skip.
