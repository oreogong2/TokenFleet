# TokenFleet Frontend Design System

## 1. Visual Theme & Atmosphere

TokenFleet is an AI usage log, not a generic analytics dashboard. Its visual
language combines warm paper, precise ledger lines, square signal marks, and a
single deep green accent. Pages should feel calm, accountable, and easy to scan.
The first three-second read is always: my usage, my position, and what composed
the number.

## 2. Color Palette & Roles

- Paper: `#f4f0e6` — page background.
- Surface: `#fffdf7` — content and dialog surfaces.
- Ink: `#17211c` — primary text and strong rules.
- Muted ink: `#657068` — explanatory text.
- Ledger line: `rgba(23, 33, 28, 0.14)` — standard 1 px divisions.
- Token green: `#1d774f` — primary action, active state, chart bars.
- Mint: `#dcefe2` — selected and positive surfaces.
- Orange: `#d66336` — secondary model and warning emphasis.
- Error: `#b42318` — destructive or invalid states only.

Green is reserved for interaction, progress, and verified status. It is not a
decorative wash. Pages use one light theme; overlays may use a charcoal scrim.

## 3. Typography Rules

- Chinese UI and body: `-apple-system, BlinkMacSystemFont, "PingFang SC",
  "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans SC", sans-serif`.
- Latin labels and numeric values: `"Avenir Next", "SF Pro Display",
  ui-monospace, "SFMono-Regular", Menlo, monospace`.
- Chinese body is at least 14 px on Web and 13 pt in compact macOS surfaces,
  with 1.5 or greater line height.
- Chinese weights are 400, 500, or 600. No italic text.
- Numeric comparison uses tabular numerals.
- Display titles use `clamp()` on Web and stay within two lines.

## 4. Component Styling

- Buttons and fields use 4–6 px radii; content panels use 8–12 px.
- Standard borders are 1 px ledger lines.
- Primary buttons use Token green with light text.
- Secondary buttons use transparent or paper surfaces with an ink border.
- Filter controls are direct segmented buttons, not select menus followed by an
  “apply” action.
- Ranking lists place the current member first in a distinct mint ledger row,
  followed by a clearly marked top three.
- Do not synthesize avatars. Nickname and rank are the identity layer until a
  user-authorized avatar source exists.
- Share preview has one entry point and only two actions: “保存图片” and “关闭”.

## 5. Layout Principles

- Base spacing unit: 4 px; primary rhythm: 8, 12, 16, 24, 32, 48, 64.
- Web content max width: 1280 px.
- Prefer hairline divisions and asymmetric editorial grids over card walls.
- Leaderboards prioritize the current member, then the top three, then the rest.
- Mac App primary navigation is consolidated into “用量 / 社群 / 设置”.
- Usage ranges are “今天 / 近 7 天 / 近 30 天 / 近 90 天 / 全部”.

## 6. Depth & Elevation

- Flat: paper background, no shadow.
- Ledger: 1 px ink-tinted border.
- Panel: surface plus a four-layer low-opacity warm shadow.
- Dialog: charcoal scrim plus a restrained multi-layer shadow.
- Focus: 2 px Token green ring with 2 px offset.

Depth communicates interaction or temporary elevation; it is never used merely
to turn every section into a card.

## 7. Do's and Don'ts

### Do

- Show the current value, target denominator, and percentage together.
- Show observed tool and model names with their actual usage.
- Keep public copy explicit about what is and is not uploaded.
- Use real empty, loading, error, and success states.
- Show chart values on mouse hover, keyboard focus, and touch selection.
- Keep exported ranking images to the current member, top 10, and one scannable
  QR code for the complete ranking.

### Don't

- Do not use a giant ring, dark competitor-style long list, capsule tag wall, or
  oversized marketing headline.
- Do not use “圈数” or “航段” when the direct meaning is Token usage or progress.
- Do not claim support for a tool or model that has not actually been observed.
- Do not show fake avatars or infer WeChat identity from a nickname.
- Do not duplicate share buttons or provide an unexplained “系统分享” action.

## 8. Responsive Behavior

- Below 900 px, filter rails may scroll horizontally and leaderboard metrics
  split into two readable rows.
- Below 640 px, leaderboard rows retain rank, nickname, leading models, and total;
  the four Token classes move into the detail view.
- Touch targets are at least 44 px where the platform permits.
- Chart selection works by tap on touch devices and never depends on hover alone.
- Long nicknames, tool names, and model names truncate without moving numeric
  columns.

## 9. Motion Philosophy

- Visual adventure: 7/10 — editorial structure and ledger identity, not novelty.
- Motion intensity: 3/10 — only feedback and state continuity.
- Information density: 7/10 — compact but readable.
- Button press feedback: 100–160 ms with a 0.97 scale.
- Tooltips and small popovers: 125–180 ms ease-out.
- Dialogs: 200–260 ms, entering from 0.95 scale and opacity 0.
- Frequent keyboard actions do not animate.
- Motion uses transform and opacity, respects reduced motion, and never exceeds
  300 ms for routine UI.
