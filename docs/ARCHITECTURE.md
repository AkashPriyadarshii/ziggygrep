# ziggygrep ARCHITECTURE

## Modules

- `main.zig`: parse args, build walker + pool, merge, print, exit.
- `Args.zig`: CLI parsing, unit tests beside the parser.
- `Walk.zig`: recursive `std.fs.Dir.iterate`, yields file paths.
  Skips dotfiles and `.git`. No gitignore engine in v0.1.
- `Search.zig`: literal scan over a file buffer. Returns match
  spans `(lineno, start, end)`. Owns the prefilter, short-line
  skip, jump-past-line, and NUL policy.
- `Out.zig`: `path:lineno:line` formatting, `-l`/`-c`
  variants, max-columns truncation on UTF-8 boundaries,
  buffered single-flush writes.

## Data flow

```
walk -> paths -> thread pool -> Search.scan(file) -> spans
     -> per-thread arena bytes -> sorted merge -> stdout
```

## Concurrency

One `std.Thread.Pool`. One file per task. Each worker owns a
byte arena plus a path list. Merge sorts files by path, then
concatenates arena slices in order. Walk and search run in
sequence; no nested pools (two pools oversubscribe small
machines, measured on 2C/4T).

## I/O

Streaming reads, no mmap. Buffered stdout, one flush at the end.
Flat memory on any input size, works on pipes.

## Error handling

Unreadable files: `ziggygrep: path: reason` on stderr,
processing continues. Named directories searched recursively;
recursion skips directories silently only when discovered, not
when named.
