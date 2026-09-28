# Contributing

## How to contribute

1. Fork, branch, open a PR with the template below.
2. Keep the diff small. One concern per PR.
3. Stdlib before deps. There are no deps; keep it that way.
4. Non-trivial logic ships with one runnable check (`zig build test`).
5. Update docs when behavior changes. README describes the present, CHANGELOG records the past.

## PR template

```markdown
## Summary
[1-2 sentences: what this PR does.]

## Motivation and Context
[Why this change is necessary. What problem does it solve?]

## Related Issues
[Fixes #123, or Related to #789, or none.]

## What changed
- [Bulleted technical changes for larger PRs.]

## Testing Instructions
- Run `zig build test` to ensure all tests pass.
- [Manual verification steps, bench corpus + rerun commands when perf-relevant.]
```

## Build and test

```bash
zig build -Doptimize=ReleaseFast
zig build test
```

## Style

- Terse comments. Explain why, never what.
- Active voice in docs. No em dashes in prose.
- No buzzwords (seamless, robust, leverage, cutting-edge). Name the mechanism.
