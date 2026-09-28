# ziggygrep ARCHITECTURE

## Modules

- `main.zig`: parse args, build walker + pool, merge, print, exit.
- `Args.zig`: CLI parsing, unit tests beside the parser.
- `Walk.zig`: recursive `std.fs.Dir.iterate`, yields file paths.
  Skips dotfiles and `.git`. No gitignore engine in v0.1.
- `Search.zig`: first-byte prefilter + `eql` verify over whole chunks. Line bounding, lineno gaps, and NUL suppression run on verified hits only. Fused emit writes matches straight to the caller buffer, no spans array. Owns the NUL policy.
- `Out.zig`: `path:lineno:line` formatting, `-l`/`-c`
  variants, max-columns truncation on UTF-8 boundaries,
  buffered single-flush writes.

## Data flow

```
walk -> file list -> batch index -> workers scanToBuf(file) -> fused emit
     -> per-worker result lists -> sorted merge -> stdout (one flush)
```

## Concurrency

Fixed `fetchAdd(8)` batches from one file list. Each worker owns scratch/carry/chunk buffers reused across files. Merge sorts by path, then concatenates in order. Single-file roots skip the pool (direct scan, no spawn). No nested pools (two pools oversubscribe small machines, measured on 2C/4T).

## I/O

Streaming reads, no mmap. Buffered stdout, one flush at the end.
Flat memory on any input size, works on pipes.

## Error handling

Unreadable files: `ziggygrep: path: reason` on stderr,
processing continues. Named directories searched recursively;
recursion skips directories silently only when discovered, not
when named.
