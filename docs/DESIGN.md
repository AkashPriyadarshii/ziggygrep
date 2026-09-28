# ziggygrep DESIGN

CLI tool. No web UI, no landing page in this repo. This file
records the interface decisions so output stays stable.

## Output shape

Default: `path:lineno:line`, one match per line, UTF-8.

```
src/engine.zig:42:    map: HashMap([]const u8, Result),
```

`-l`: file paths only, one per line, sorted.
`-c`: `path:count` per file, sorted. Single file prints the
bare count (ripgrep compatible).

## Truncation

`-M N` cuts lines longer than N columns on a UTF-8 boundary.
`0` disables. Default: no truncation in v0.1 (explicit beats
surprise; ripgrep-compatible capping arrives with a flag).

## Errors

`ziggygrep: path: reason` on stderr. Exit 0 on match, 1 on no
match, 2 on usage or I/O error.

## Dials

ENERGY 1 / RHYTHM 1 / MOTION 1. Terminal output has no motion
or decoration. Clarity is the design.
