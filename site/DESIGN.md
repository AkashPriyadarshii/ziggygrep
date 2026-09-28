# ziggygrep site DESIGN.md

Design spec for `site/`. Multi file page: `index.html` plus `style.css` plus `script.js`. No build step. No external JS. No external fonts.

## Design Read

Reading this as: Persuade mode CLI tool landing plus Read mode technical docs for systems programmers and AI agent builders, with a carbon instrument console language, leaning toward ClickHouse acid-on-carbon industrial telemetry.

Same structural grammar as jev-superpowers (sticky header, hero split with terminal, verdict band, ruled sections, code block with copy key, author slab, four column footer). Different palette, different voice, different section order. Dark carbon instrument, not another light paper page. Never a centered hero. Never three equal cards.

## Substrate and pigment

One substrate only. Carbon console (ClickHouse lineage, awesome-design-md clickhouse entry: acid `#FAFF69` on near black `#0A0A0A`).

- Ground: `#0A0A0A` (carbon, refined, never pure black text on white)
- Surface 1: `#141414` (terminal, code block)
- Surface 2: `#1F1F1F` (tab active, hover fills)
- Hairline: `#2E2E2E`
- Hairline strong: `#404040`
- Ink: `#F4F4EF` (warm white text)
- Body: `#B9B9B0`
- Muted: `#8E8E85` (secondary text, about 6.4:1 on ground, AA)
- Acid: `#FAFF69` (primary accent, about 17:1 on ground; verdict chips, ziggygrep cells, tab rail, primary action)
- Acid deep: `#E6EB52` (hover state)
- Amber: `#F5A623` (delta chips, step indices, stamps only)
- Alert red: `#EF4444` (errors and ripgrep slower cells only, never decoration)
- Match wash: `rgba(250, 255, 105, 0.08)` (table header fill only)

Causal derivation: carbon picked from ClickHouse archetype so acid match rows read at full contrast with zero glow filters. Acid reserved for ziggygrep wins and the primary action only. Amber reserved for deltas and stamps only. Red never decorates.

## Type

2 plus 1 ceiling. Zero webfont fetch. System stacks only.

- Display: `"Arial Narrow", "Helvetica Neue Condensed", Impact, sans-serif` (structural headlines, uppercase, condensed punch)
- Body: `Candara, "Segoe UI", system-ui, sans-serif` (copy, UI, buttons)
- Code: `"JetBrains Mono", "Cascadia Mono", Consolas, monospace` (terminal, tables, stamps, eyebrows)

Macro headlines use fluid clamp with `-0.02em` tracking. Micro labels are uppercase mono with wide tracking for telemetry framing.

## Radii, concentric

- Outer card: `R_outer = 10px`
- Card padding: `p = 8px`
- Inner chip: `r_inner = max(0, R_outer - p) = 2px`
- Concentric rule: nested chips use `r_inner` derived from parent outer minus padding. Radius tokens: `10px / 4px / 2px`. Hard offset shadow `2px 2px 0 rgba(0,0,0,0.4)` on terminal, code block, and primary button only. Flat everywhere else.

## Motion

Concrete curves only. No generic easing.

- Micro tap: `cubic-bezier(0.16, 1, 0.3, 1)` at `50ms` transform plus `200ms` shadow for buttons.
- Tab switch: instant `display` swap, no fade. Color transitions on tabs use `cubic-bezier(0.16, 1, 0.3, 1)` at `200ms` on real properties only (`color, background-color, border-color`).
- Copy tick: label swap to `Copied` for `1200ms`, no animation.
- Never use `transition: all`. Ban list enforced: transition real properties only.
- `prefers-reduced-motion` fallback: smooth scroll off, all transitions collapse to instant.
- Focus: never suppress outline without replacement. `:focus-visible` gets a `2px` acid outline with `2px` offset on every interactive element.

## Layout

Sticky header with brand, section nav, and GitHub action. Hero split: claim left, live terminal right with Full, Count, and Files tabs plus a verdict band. Ruled sections in fixed order: Why (ruled rows), Bench (parity chips plus method), Internals (three pipeline steps), Quickstart (code block plus numbered steps), Limits (ruled rows), Ecosystem (ruled link rows), author slab, four column footer (Navigation, Ecosystem, Author, Social) plus bottom line. Icon system: inline SVG paths drawn in this file only, one stroke family, brand marks from Simple Icons only.

## Design contract

- First-Read Object: the hero terminal Full tab with ziggygrep ms vs rg ms plus the verdict band.
- Primary Action: copy the install command, then open the v0.1.0 release.
- Finish gate: pass or hold. Hold if bench numbers differ from README, if any link 404s, if contrast fails AA, if page weight crosses budget.
- Empty states: no filter widgets ship, so no empty state copy ships. Nothing renders a bare no data string.

## Performance budget

- Performance budget: HTML plus CSS plus JS under `90KB`, zero frameworks, zero font fetch, page weight under `300KB` total with logo.
- Targets: LCP under `1.5s` on 4G, CLS `0`, INP under `100ms`. Tab switches cause no layout shift. Tables use tabular numerals.
- Drift story: token drift checked by diffing the palette block in `site/style.css` against this spec on every edit. Baseline is this file. Any token change without a matching spec edit fails on change review (fail-on-change via visual-diff of the swatch row).
