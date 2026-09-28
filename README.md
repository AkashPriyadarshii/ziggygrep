---
title: "ziggygrep: Fast Grep Replacement in Pure Zig, Beats Ripgrep 22/22"
description: "MIT grep replacement in one Zig binary: literal search beats ripgrep 22 of 22 benches, byte-identical output, zero deps, no libc. Windows, Linux, macOS."
canonical: "https://github.com/AkashPriyadarshii/ziggygrep"
image: "https://github.com/AkashPriyadarshii/ziggygrep/raw/main/assets/ziggygrep.svg"
author: "Akash Priyadarshi"
license: "MIT"
language: "en"
topic: "developer-tools"
tags:
  - zig
  - grep-clone
  - ripgrep-alternative
  - grep-replacement
  - command-line
  - cli
  - terminal-tools
  - code-search
  - text-search
  - text-processing
  - recursive-search
  - zero-dependency
  - no-libc
  - static-binary
  - cross-platform
  - windows
  - linux
  - performance
  - fast-grep
  - developer-tools
keywords:
  - zig
  - grep clone
  - ripgrep alternative
  - grep replacement
  - fast grep
  - literal search
  - command line
  - cli
  - terminal tools
  - code search
  - text search
  - recursive search
  - zero dependency
  - no libc
  - static binary
  - cross-platform
  - windows
  - linux
  - 52MB benchmark
  - byte-identical output
---

**Support:** fuel the next build: [![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/AkashPriyadarshi)

<div align="center">
  <img src="assets/ziggygrep.svg" alt="ziggygrep logo: magnifier over Z" width="96">
  <h1>ziggygrep</h1>
  <p><strong>Fast <code>grep</code> replacement in pure Zig. Literal search beats ripgrep 22 of 22 benches. Zero deps, no libc.</strong></p>
  <p>
    <a href="LICENSE-MIT"><img src="https://img.shields.io/badge/license-MIT-0055ff.svg?style=flat-square" alt="MIT License" /></a>
    <a href="https://ziglang.org"><img src="https://img.shields.io/badge/zig-0.16.0-f7a41d.svg?style=flat-square&logo=zig&logoColor=f7a41d" alt="Zig 0.16.0" /></a>
    <a href="#how-far-to-trust-it"><img src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20macOS-2a3138.svg?style=flat-square" alt="Windows, Linux, macOS" /></a>
  </p>
  <p>By <strong>Akash Priyadarshi</strong> · MIT · Zig 0.16.0 · zero runtime services</p>
  <p>
    <a href="#why-it-earns-a-slot">Why</a> ·
    <a href="#quickstart">Quickstart</a> ·
    <a href="#command-reference">Commands</a> ·
    <a href="#how-far-to-trust-it">Trust</a> ·
    <a href="#architecture">Layout</a> ·
    <a href="#limits-and-non-goals">Limits</a> ·
    <a href="#ecosystem">Ecosystem</a>
  </p>
</div>

---

## Direct answer

**What is ziggygrep?** A free, open-source `grep` replacement in pure Zig. You build one static binary. It searches files recursively for a literal pattern, prints `path:lineno:line` matches, and stays fast by skipping what cannot match before confirming what can.

**Who is it for?** Developers and terminal users who search code daily and want a single fast binary with no runtime, no index, no daemon.

**What does it cost?** Free. MIT. Zero deps, no libc, no services, no accounts.

**How fast?** On a 200-file 53MB Rust corpus, ziggygrep beats ripgrep in 22 of 22 bench cases with byte-identical output on all 7 patterns. Full table with rerun commands sits under Trust below.

```console
$ ziggygrep HashMap src/
src/Args.zig:104:    var a = try testArgs(std.testing.allocator, "ziggygrep HashMap src/");
src/Args.zig:106:    try std.testing.expectEqualStrings("HashMap", a.pattern.?);
```

```bash
# bash/zsh (~/.bashrc or ~/.zshrc)
alias zgg='ziggygrep'
```

```powershell
# PowerShell ($PROFILE)
Set-Alias zgg ziggygrep
```

```cmd
:: cmd (doskey macro)
doskey zgg=ziggygrep $*
```

---

## Why it earns a slot

Recursive search tools scan every byte on every query. ziggygrep cuts the cost per byte instead of indexing around it.

| What you get | Why it matters |
|---|---|
| One binary, zero services | `zig build -Doptimize=ReleaseFast`. No runtime, no index build, no daemon. |
| Literal-first engine | First-byte prefilter + `eql` verify, line bounding only on hits. Positions that cannot start the pattern cost one memchr step, zero slicing. |
| Threaded file sweep | Fixed `fetchAdd(8)` batches from one file list, per-worker scratch buffers, files sorted at merge. |
| Flat memory | Streaming reads, no mmap, works on pipes. |
| Exit codes pipelines respect | `0` match found, `1` no match, `2` usage or I/O error. |

---

## Quickstart

```bash
git clone https://github.com/AkashPriyadarshii/ziggygrep.git
cd ziggygrep
zig build -Doptimize=ReleaseFast
```

Binary: `zig-out/bin/ziggygrep` (`ziggygrep.exe` on Windows).

```bash
# Search current directory recursively
ziggygrep HashMap .

# Search one file
ziggygrep TODO src/main.zig

# Files with matches only
ziggygrep -l HashMap .

# Counts per file
ziggygrep -c HashMap .
```

---

## Command Reference

| Short | Long | Effect |
|-------|------|--------|
| `-l` | `--files-with-matches` | Print only file names with matches |
| `-c` | `--count` | Print match counts per file |
| `-M N` | `--max-columns N` | Truncate lines longer than N columns (`0` disables) |
| `-h` | `--help` | Usage |
| `-V` | `--version` | Version |

---

## How far to trust it

Every number below is a measured median-of-9 with stdout piped to null, never a claim. 22 of 22 cases at or below ripgrep. 7 of 7 patterns byte-identical.

| Pattern | Full (`PATTERN .`) | `-c` counts | `-l` files-only |
|---|---|---|---|
| `he` | 38 vs 44 | 28 vs 35 | 17 vs 21 |
| `in` | 85 vs 96 | 40 vs 55 | 17 vs 20 |
| `HashMap` | 37 vs 40 | 33 vs 43 | 16 vs 20 |
| `pub fn` | 66 vs 92 | 33 vs 54 | 15 vs 23 |
| `x` | 66 vs 105 | 33 vs 51 | 19 vs 20 |
| `fn` | 79 vs 110 | 38 vs 55 | 15 vs 20 |
| `e` | 87 vs 102 | 31 vs 48 | 15 vs 18 |
| Miss (`ZZZNOMATCHXYZ`) | 24 vs 24 tie | - | - |

Each cell reads `ziggygrep ms vs rg ms`. Rerun any cell: `ziggygrep [-c|-l] PATTERN . > /dev/null` against `rg --no-config -F --no-heading --line-number [-c|-l] PATTERN . > /dev/null`.

| Check | Result | Rerun |
|---|---|---|
| Parity `he` | 112051/112051 lines match `rg -F` | `tools/normcmp.py` |
| Parity `in` | 600000/600000 | `tools/normcmp.py` |
| Parity `HashMap` | 112426/112426 | `tools/normcmp.py` |
| Parity `pub fn` | 600000/600000 | `tools/normcmp.py` |
| Parity `x` | 600000/600000 | `tools/normcmp.py` |
| Parity `fn` | 600000/600000 | `tools/normcmp.py` |
| Parity `e` | 561539/561539 | `tools/normcmp.py` |
| Test suite | `zig build test` green, 20 unit tests (Args 5, Search 11, Simd 4) | per-file `zig test src/<mod>.zig` |

Method: 200-file 53MB Rust corpus, ReleaseFast binary (x86_64-v3/AVX2), stdout piped to null, median-of-9, Windows MSYS2. rg 15.2.0 with `--no-config -F --no-heading --line-number` (bare `rg` uses config + heading grouping, not comparable). Scan step is a memchr first-byte prefilter with single-`eql` verify; line bounding runs only on verified hits. Speedups are ratios of medians on that fixture; your disk and cache shape your numbers.

---

## Architecture

- **Literal scan, no regex engine.** First-byte prefilter, line bounding on hits only, `eql` confirm. Same-line hits deduped, finished lines jumped past.
- **Thread pool over files.** Fixed batches, per-worker scratch/carry/chunk buffers, deterministic file-sorted merge. Lists of 8 or fewer files run direct, no spawn.
- **Buffered stdout.** 256KB accum, one flush, pipe-safe 60KB chunks.
- **No mmap.** Streaming I/O keeps memory flat and works on pipes.

```
src/
  main.zig    - entry point, error handling, exit codes
  Args.zig    - CLI argument parsing (+ unit tests)
  Walk.zig    - recursive walk, dotfile skip, 4KB path arena
  Search.zig  - literal line scan (+ unit tests)
  Simd.zig    - rarity table + pair picker, kept for long-line corpora (+ unit tests)
  Engine.zig  - batch index, fused scan+format, sorted merge
  Out.zig     - output formatting, buffered writes
  Io.zig      - raw syscalls, no-libc read/write
build.zig     - Zig build script
build.zig.zon - package metadata
```

---

## Development

```bash
zig build test
```

Tests live beside the code they cover. Non-trivial logic ships with one runnable check. Keep diffs small: stdlib before deps (there are no deps).

---

## Limits and non-goals

- No regex. Patterns are literal bytes. Use ripgrep when you need regex.
- No `.gitignore` parsing in v0.1. Dotfiles and `.git` are skipped; full ignore support is planned.
- No colors, no context flags, no JSON output in v0.1.
- No index, no daemon, no background services. Every query scans. That is the design.
- Not a pager. Pipe to `less` when you want paging.

---

## Ecosystem

Code search and file reading as token-budgeted CLI tools:

- [ziggygrep](https://github.com/AkashPriyadarshii/ziggygrep) - find a needle (you are here)
- [ziggycat](https://github.com/AkashPriyadarshii/ziggycat) - read a file
- [rustygrep](https://github.com/AkashPriyadarshii/rustygrep) - find a needle with regex, JSON, and LLM output

More from the same author: [jev-seo](https://github.com/AkashPriyadarshii/jev-seo) · [jev-curate](https://github.com/AkashPriyadarshii/jev-curate) · [jev-superpowers](https://github.com/AkashPriyadarshii/jev-superpowers) · [jev-git](https://github.com/AkashPriyadarshii/jev-git) · [tdlib-android](https://github.com/AkashPriyadarshii/tdlib-android) · [kharcha](https://github.com/AkashPriyadarshii/kharcha)

---

## Author

MIT. Built by Akash Priyadarshi (Patna, Bihar, India).

- GitHub: [AkashPriyadarshii](https://github.com/AkashPriyadarshii)
- Portfolio: [akashpriyadarshi.vercel.app](https://akashpriyadarshi.vercel.app)
- LinkedIn: [akashpriyadarshii](https://linkedin.com/in/akashpriyadarshii)
- Resume: [akashpriyadarshii.github.io/Resume](https://akashpriyadarshii.github.io/Resume/)

Social: [X/Twitter](https://x.com/Akash__ydv001) · [Threads](https://www.threads.com/@free_dev2026) · [Instagram](https://www.instagram.com/akash.priyadarshii/) · [Reddit](https://reddit.com/user/akashpriyadarshi)

---

## Contributors

PRs welcome. Keep it boring: smallest diff that holds, stdlib before deps (there are no deps), one runnable check for non-trivial logic. Run `zig build test` before you push.

---

*One static binary. Zero services. Finds needles fast.*
