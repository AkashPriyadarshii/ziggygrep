# Changelog

All notable changes to this project. Format follows Keep a Changelog:
Added, Changed, Fixed per release. No changelog-speak in the README.

## [Unreleased]

- First-byte prefilter + single-`eql` verify for every needle length: memchr skips 32B per step, line bounding runs on verified hits only. Short path (`he`) drops 129 to 40ms; dense path (`HashMap`) 82 to 35ms.
- `anyChunk` routed through the same prefilter: `-l` wins every pattern (`e -l` 33 to 12ms).
- Single-thread path fused scan+format: `spans` alloc removed, per-hit header built once on the stack. 22 of 22 bench cases at or below rg, 7 of 7 patterns byte-identical.
