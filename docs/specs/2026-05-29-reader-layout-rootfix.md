# Reader Layout Root-Fix Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax. This plan fixes three
> reader regressions reported on Windows desktop (suspected on Android too), reading a
> **vertical-rl** Japanese audiobook.

**Goal:** Root-cause-fix three reader-layout regressions in `ReaderHibikiPage` / the JS
pagination engine: (1) bottom control bar renders at the top of the screen; (2) text drifts
further and further on each page turn; (3) rapid UI changes snap the reader back to chapter start.

**Architecture:** The reader is a full-screen `InAppWebView` overlaid by Flutter chrome
(`Positioned` bars) inside a `Stack`. A JS pagination engine (`reader_pagination_scripts.dart`)
column-paginates the EPUB and tracks scroll position; CSS in `reader_content_styles.dart`
reserves chrome space via `--chrome-top-inset` / `--chrome-bottom-inset` body padding.

**Tech Stack:** Flutter 3.41.6 / Dart 3.11.4, flutter_inappwebview, CSS multicol, Drift.

---

## Root-Cause Summary

| # | Symptom | Suspected commit | Root cause (confidence) |
|---|---------|------------------|--------------------------|
| 1 | 底栏跑到屏幕顶部 | `1038e899a` gamepad focus escape | **Confirmed.** `Stack` child is `FocusScope(node, child: _buildBottomChrome())`, and `_buildBottomChrome()` returns a `Positioned`. The `FocusScope` interposes a render node, so `Positioned`'s `StackParentData` no longer attaches to the `Stack` → bar falls back to the stack's default top-left alignment. |
| 2 | 翻页文字偏移越来越大 | `0ff9864a7` chrome insets / `7ca27902d` dart dims | **Hypothesis.** Vertical scroll step `columnPitch = clientHeight (= --page-height)` no longer equals the true CSS column period after chrome insets enlarged body padding (content box shrank, pitch did not). Must confirm with on-device `[HoshiPagination]` logs. |
| 3 | 快速变动 UI 回章节开头 | `0ff9864a7` full-screen reflow | **Hypothesis.** `_syncPageSize` runs a full `_navigateToChapter` reload on any width change; rapid metric churn races, and a transient `progress == 0` reload lands at chapter start. `_applyStylesLive` also never invalidates `paginationMetrics`. Must confirm on-device. |

> Systematic-debugging rule: symptom 1 is confirmed and independent → fix + test first.
> Symptoms 2 & 3 require device evidence (the engine is heavily `console.log`-instrumented)
> BEFORE writing their fix code.

---

## File Structure

- `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` — Stack chrome wiring (#1), `_syncPageSize` reload race (#3).
- `hibiki/lib/src/reader/reader_pagination_scripts.dart` — vertical `columnPitch` vs column period (#2), metrics invalidation (#3).
- `hibiki/test/widgets/reader_bottom_chrome_position_test.dart` — NEW, regression test for #1.
- `docs/REGRESSION_BUGS.md` — record reproduced regressions + evidence paths.

---

## Task 1: Fix bottom chrome positioned-in-stack detachment (Symptom 1)

**Files:**
- Test: `hibiki/test/widgets/reader_bottom_chrome_position_test.dart` (create)
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` (Stack child ~line 1005; `_buildAudiobookBar` ~3557; `_buildSettingsBar` ~3591)

- [ ] **Step 1: Write the failing/repro test** — pump a `Stack(fit: expand)` whose only
  child mirrors the reader pattern `FocusScope(node, child: Positioned(bottom:0, child: marker))`,
  and assert the marker's top-left Y is in the bottom half of the stack. This reproduces the
  detachment (test reveals whether Flutter throws or mispositions).

- [ ] **Step 2: Run it** — `flutter test test/widgets/reader_bottom_chrome_position_test.dart`.
  Expect FAIL (marker at top, or ParentData FlutterError).

- [ ] **Step 3: Fix** — In the build `Stack`, change
  `FocusScope(node: _chromeFocusScope, child: _buildBottomChrome())` → `_buildBottomChrome()`.
  Move the `FocusScope(node: _chromeFocusScope, …)` INSIDE `_buildAudiobookBar` and
  `_buildSettingsBar`, wrapping each bar's `Column` so the `Positioned` stays a direct `Stack`
  child while focus scoping is preserved.

- [ ] **Step 4: Update the test** to the fixed structure (`Positioned(bottom:0, child: FocusScope(node, child: marker))`) and assert marker is in the bottom half. Run → PASS.

- [ ] **Step 5: Verify chrome focus escape still works** — confirm `_toggleChrome(moveFocusToChrome:true)`'s post-frame `_chromeFocusScope.requestFocus()` still targets a mounted FocusScope (it mounts with the bar). Run full `flutter analyze`.

- [ ] **Step 6: Commit** — `fix(reader): keep bottom-chrome Positioned a direct Stack child (bar no longer renders at top)`.

---

## Task 2: Gather on-device evidence for drift + reset (Symptoms 2 & 3)

**Files:** none (evidence only). Device: `emulator-5554` (Android 15) and/or Windows desktop.

- [ ] **Step 1: Build & install** the app on the emulator (or `flutter run -d windows`).
- [ ] **Step 2: Open** the かがみの孤城 audiobook (vertical-rl) — fixtures per `hibiki/CLAUDE.md`.
- [ ] **Step 3: Capture logs while paging forward 10+ times** — `[HoshiPagination] ctx:` and
  `paginate … drift=` lines. Record `pitch`, `cssGap`, `scrollH`, `clientH`, and whether the
  rendered first-visible char creeps. Save to `.codex-test/`.
- [ ] **Step 4: Capture logs while rapidly resizing the window (desktop) / rotating (Android) /
  toggling chrome + appearance sheet** — note any reload to progress 0 and stale metrics.
- [ ] **Step 5: Update `docs/REGRESSION_BUGS.md`** with confirmed root cause + evidence paths,
  then refine Task 3 & Task 4 fix code from the measured numbers (no guessing).

---

## Task 3: Fix cumulative page-turn drift (Symptom 2) — code finalized after Task 2

**Files:** `hibiki/lib/src/reader/reader_pagination_scripts.dart`; test `hibiki/test/reader/reader_pagination_scripts_test.dart`.

- [ ] Make the vertical scroll step equal the true CSS column period (column-width + column-gap)
  derived from measured DOM geometry, not the full `--page-height`; OR make `--page-height`/content
  box and `columnPitch` consistent so `k * columnPitch` always lands on a column boundary. Exact
  formula chosen from Task 2 numbers.
- [ ] Add a unit test asserting `columnPitch` equals the measured column period for representative
  vertical + horizontal geometries.
- [ ] Verify on device: page forward 20×, first-visible char stays page-aligned (no creep).
- [ ] Commit.

---

## Task 4: Fix rapid-UI reset to chapter start (Symptom 3) — code finalized after Task 2

**Files:** `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`; `reader_pagination_scripts.dart`.

- [ ] Debounce/guard `_syncPageSize` so overlapping metric churn cannot launch concurrent
  `_navigateToChapter` reloads, and never reload at progress 0 when a valid position is known.
- [ ] Prefer in-place re-pagination (`updatePageSize` + restore measured char offset) over a full
  chapter reload on width change where possible, matching the height-change path.
- [ ] Invalidate `paginationMetrics` in `_applyStylesLive` after a layout-affecting style change.
- [ ] Verify on device: rapid resize / rotate / chrome toggle keeps reading position.
- [ ] Commit.

---

## Task 5: Code review + final verification

- [ ] `dart format .` + `flutter test` (full) green.
- [ ] Spawn code-reviewer subagent with `model: "opus"` (per `hibiki/CLAUDE.md`).
- [ ] Address review findings, re-review until pass.
- [ ] Device re-verify all three original failure paths; record evidence.
