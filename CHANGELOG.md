# Changelog

All notable changes to this project. Format follows Keep a Changelog:
Added, Changed, Fixed per release. No changelog-speak in the README.

## [Unreleased]

- Packed-pair SIMD confirm (`Simd.zig`): two rarest needle bytes by static frequency table, 32-wide compare, verify survivors. 4 tests incl. 300-line fuzz vs scalar.
- Release builds target x86_64-v3 (AVX2), matching what rg runtime-dispatches to. Debug/test stay baseline. Explicit `-Dtarget` wins.
- Full 44 to 43ms, miss holds the win (20 vs 21). `-l`/`-c` regressed vs last round (noise + v3 codegen shuffle); fused scan+format is the queued fix.
