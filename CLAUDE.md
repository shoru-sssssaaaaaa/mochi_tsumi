# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project overview

「もちっとつみつみ」 is an offline iOS puzzle game where the player stacks soft-body mochi above a goal line. The whole game (physics, rendering, UI, audio, stages) lives in a single HTML file; the Swift side is a thin WKWebView shell that adds native save storage and haptics.

- Platform: iPhone only, portrait, iOS 16.0+, Swift 5, SwiftUI app lifecycle
- Bundle ID: `com.shotasakaguchi.mochittotsumitsumi`
- No network access, no third-party dependencies, no package manager, no build step for the web part

## Layout

```
MochittoTsumitsumi.xcodeproj/     Xcode project (objectVersion 56, classic groups — not synchronized folders)
MochittoTsumitsumi/
  MochittoTsumitsumiApp.swift     App entry; sets AVAudioSession to .ambient
  GameView.swift                  WKWebView wrapper + GameBridge (JS <-> native)
  web/index.html                  The entire game (HTML/CSS/JS, ~700 lines, no external assets)
  Assets.xcassets                 AppIcon, LaunchBackground color
  Info.plist                      Launch screen only; other keys are INFOPLIST_KEY_* build settings in pbxproj
  PrivacyInfo.xcprivacy           No tracking/collection; declares UserDefaults (CA92.1)
AppStore/                         Store listing text, screenshots, GitHub Pages site (support/privacy)
リリース手順.md                   Release guide (Japanese, for a non-developer audience)
```

## Commands

There is no test target and no linter configured.

```sh
# Build for simulator (scheme is Xcode's auto-generated one)
xcodebuild -project MochittoTsumitsumi.xcodeproj -scheme MochittoTsumitsumi \
  -destination 'generic/platform=iOS Simulator' build

# Play the game in a desktop browser (no server needed; save goes to localStorage)
open MochittoTsumitsumi/web/index.html
```

`xcodebuild` fails inside the Claude Code sandbox (cannot write its cache under `/var/folders`); it needs to run outside the sandbox.

Quick JS syntax check without Xcode:

```sh
awk '/<script>/{f=1;next}/<\/script>/{f=0}f' MochittoTsumitsumi/web/index.html > "$TMPDIR/game.js" && node --check "$TMPDIR/game.js"
```

## Architecture

### Native bridge (`GameView.swift` ⇄ `web/index.html`)

| Direction | Mechanism | Payload |
|---|---|---|
| Native → JS | `WKUserScript` at document start sets `window.__MOCHI_SAVE__` | The saved JSON **as a string** (JS calls `JSON.parse` on it) |
| JS → Native | `webkit.messageHandlers.save.postMessage(json)` | JSON string, rejected if ≥ 10,000 bytes; stored in `UserDefaults` key `mochitto-save` |
| JS → Native | `webkit.messageHandlers.haptic.postMessage(kind)` | `"light"` / `"soft"` / `"success"` / `"warning"` |

- In a browser `NATIVE` is null, so `SAVE` falls back to `localStorage['mochitto-save']` and `buzz()` is a no-op. Keep this fallback working — the game must stay playable as a plain HTML file.
- Save keys currently used: `unlocked` (highest cleared stage index + 1), `muted`, `seenHelp`, `records` (`{stages:{[idx]:bestScore}, free:bestScore, plays}`).
- On `webViewWebContentProcessDidTerminate` the save script is re-installed with the latest UserDefaults value and the page reloads.
- Adding a new message handler requires both `contents.add(bridge, name:)` in `makeUIView` and a case in `userContentController(_:didReceive:)`.

### Game (`web/index.html`)

- **Fixed-timestep loop**: `loop()` accumulates real time and runs `frame()` at 60 Hz; all timers use `1/60` increments, not wall-clock.
- **Soft-body physics** (Verlet): each blob is a ring of `N=18` points. Per frame: `SUB=3` substeps × `ITER=4` constraint iterations of `shape()` (edge springs with plasticity, skip-one bend springs, area pressure) → drag → `collide()` → `solveWelds()` → `walls()`.
  - `collide()` is O(blobs² × N²) with bbox culling; `LIMIT=28` blobs in free mode and `welds.length < 500` cap keep it tractable.
  - Welds are the "sticky" contacts; kinako (`stick:0`) never welds with anything.
  - Floor glue (`p.st`) pins points to the tray until pulled past `TYPES[t].glue`.
- **Mochi types**: `TYPES` holds all tuning parameters (the comment above it explains each field). `PICK` is the order shown in the toolbar and used for procedural stages. `mikan` is a reward item, not pickable.
- **Stages**: `STAGES` defines the first 5 as `[goalHeightInMochi, inventory]`. `stageOf(i)` generates stage 6+ deterministically (LCG seeded by index); goal height is clamped by screen height. Height unit: `UNIT = 80*SCALE` px = 1 mochi; `SCALE` sets mochi size and `UNIT` follows it so stage goals stay balanced.
- **Win/lose**: `tickGame()` — clear when `stableTop()` ≥ goal for 2 s; fail when all pieces are used and everything is still for 2.5 s. While the player is holding a mochi (`down.hit`) both timers are frozen, so stretching by hand can't count toward the goal.
- **End of a run**: `finish(clear,delay)` computes the score and saves it into `game.end`; `tickEnd()` then runs `eatAll()` automatically and calls `showResult()` once every blob is eaten. Score = height ×100 (+ leftovers ×50 and speed bonus `300 - sec*5` in stage mode) − touches ×20 (`game.touches`, counted on each `pointerdown` on a mochi during play). In free mode the 食べる button ends the run.
- **Screens**: `#home` is a full-screen opaque layer (logo, CSS-drawn mochi whose colors come from `TYPES`, button panel), toggled with `showHome(on)`, which also sets `inert` on the canvas/toolbar/HUD behind it. `.card` overlays `#help` / `#result` / `#records` / `#stages` (stage select: cleared stages + the next one; its home chip is hidden until stage 1 is cleared) are switched with `showCard(id)` (only one shown) and stack above home. The app boots into `goHome()`. The toolbar's ホーム button discards the current run. Sound toggling goes through `toggleSnd()` so the toolbar and home buttons stay in sync.
- **Modes**: `game.mode` is `'menu'` | `'stage'` | `'free'`. The toolbar (`buildBar()`) is regenerated from state on every change.
- **Audio**: all sounds synthesized with WebAudio (`tone`, `noise`, `SND`). `AudioContext` is created lazily on first user gesture via `audio()`.
- **Safe area / floor**: CSS `env(safe-area-inset-*)` is read into JS through the hidden `.probe` element. `FLOOR` is the measured top of `#bar` (`getBoundingClientRect`), re-measured by a `ResizeObserver` because WKWebView fills in safe-area insets after the first layout without firing `resize`.
- **HUD**: `.hud` is a flex column (title/meter row → goal → tip); don't make its children `position:fixed` again or the goal dots and tip will overlap.

## Constraints and gotchas

- **App Review guideline 4.2**: this is a WebView-wrapped game. Do not add network requests, external fonts/CDNs, or browser-like UI (zoom, link previews, long-press menus, scroll bounce). Native value (haptics, local save, offline play) is part of the review argument — don't remove it.
- The optional font `MochiyPopOne-Regular.ttf` is picked up automatically if placed in `web/` (include `OFL.txt` with it).
- `web/` is a **folder reference** in the project, so any file dropped in it is bundled automatically. New Swift files, however, must be added to `project.pbxproj` (the project does not use synchronized groups).
- Docs (`*.md`) belong at the repo root or in `AppStore/`, not inside `MochittoTsumitsumi/`, so they don't end up in Copy Bundle Resources.
- Build number (`CURRENT_PROJECT_VERSION`) must be incremented for every App Store Connect upload.
- UI text is Japanese and intentionally hiragana-heavy for young players; keep that tone when adding strings.
- Existing code comments are in Japanese. The JS is written in a dense, minified-like style (short names, many statements per line); match it when editing `index.html`.
