# ziggygrep HANDOFF

## Status

v0.1 source complete. 22 of 22 bench cases at or below rg, 7 of 7 patterns byte-identical. Two local commits, no remote yet.

## What shipped

1. `build.zig` + `build.zig.zon` (Zig 0.16.0, exe `ziggygrep`, x86_64-v3 on release).
2. `src/Args.zig` parser + 5 unit tests.
3. `src/Search.zig` first-byte prefilter + `eql` verify, line bounding on hits, same-line dedupe, NUL-suppresses-line. 7 tests.
4. `src/Walk.zig` recursive walk, skip dotfiles + `.git`, 4KB path arena.
5. `src/Out.zig` formatting + 256KB buffered writes, pipe-safe 60KB chunks.
6. `src/Engine.zig` collect-first + `fetchAdd(8)` batch index, fused scan+format, whole-file fast path.
7. `src/main.zig` wiring, single-file fast lane, exit codes 0/1/2.
8. Bench table in README with rerun commands, medians re-measured.

## Remaining for the v0.1 tag

- Queue.zig deleted: dead MPMC ring since Loop2 collect-first. Walk takes a plain list.
- `Walk`/`Out`/`Engine`/`main`/`Io` carry zero unit tests (20 total: Args 5, Search 11, Simd 4). CI smoke covers them end to end; acceptable for v0.1.
- CI smoke runs `zig test src/Engine.zig` and `src/Out.zig` which hold zero tests: harmless pass, or trim the list to tested files.
- Tag `v0.1.0` + GitHub release with the two binaries (windows `.exe`, linux) once the user says go.

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
