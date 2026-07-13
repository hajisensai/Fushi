# Current-develop Pagination Drift Verification Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Verify that the user screenshot's vertical pagination drift is absent on current GitHub `develop`, without perturbing pagination geometry unless the current build supplies new reproduction evidence.

**Architecture:** Treat `5af42a348` (pure-V multicol body) and `8add9d5e3` (content-box clipping) as the candidate existing root fix. Prove their invariants with the repository guard tests, then verify repeated page turns in macOS WKWebView using the existing Pagination Test Book data. Open a new bug and code plan only if the current build still drifts.

**Tech Stack:** Flutter/Dart reader CSS generator, injected JavaScript pagination, flutter_test, macOS WKWebView, device screenshots/logs.

## Global Constraints

- Do not reintroduce `pageStep += bottomOverlap`.
- The paginated multicol `body` must remain `height: var(--reader-viewport-height)`.
- `pageStep` remains `columnCount × (computed columnWidth + columnGap)`.
- No reader production edit without a current-develop reproduction and measured geometry.
- Keep the unrelated 33 upstream full-suite failures out of scope.

---

### Task 1: Prove the current TODO-792 invariants

**Files:**
- Verify: `hibiki/lib/src/reader/reader_content_styles.dart`
- Verify: `hibiki/lib/src/reader/reader_pagination_scripts.dart`
- Test: `hibiki/test/reader/reader_vertical_realpitch_fix_guard_test.dart`
- Test: `hibiki/test/reader/reader_content_styles_test.dart`
- Test: `hibiki/test/reader/reader_vertical_pitch_invariant_test.dart`

**Interfaces:**
- Consumes: generated paginated CSS and `getScrollContext()` JavaScript
- Produces: automated evidence that the old 22px mismatch cannot return

- [ ] **Step 1: Run the focused reader guards**

```bash
cd hibiki
flutter test \
  test/reader/reader_vertical_realpitch_fix_guard_test.dart \
  test/reader/reader_vertical_pitch_invariant_test.dart \
  test/reader/reader_content_styles_test.dart
```

Expected: PASS.

- [ ] **Step 2: Run the checked-in headless pitch probe**

```bash
cd tool/reader_pitch_headless
npm install
node band_period_probe.js
```

Expected: average actual band period differs from nominal page step by less than 1px and page-N alignment error remains bounded rather than increasing linearly.

---

### Task 2: Verify the actual macOS reader path

**Files:**
- Use existing test data: books titled `Pagination Test Book`
- Create evidence outside git: `/tmp/hibiki-pagination-current-develop-20260713.png`

**Interfaces:**
- Consumes: the current debug macOS app and real WKWebView
- Produces: repeated-turn visual evidence on the same engine family as the report

- [ ] **Step 1: Launch the current macOS build and open a Pagination Test Book**

```bash
cd hibiki
HIBIKI_LEAK_EVIDENCE_DIR=/tmp/hibiki-page-edge-evidence \
  flutter test integration_test/reader_page_edge_leak_verify_itest.dart \
  -d macos --no-pub
```

Expected: the real WKWebView screenshot matrix passes for vertical/horizontal,
single/double-column, with PNG evidence under
`/tmp/hibiki-page-edge-evidence`.

- [ ] **Step 2: Run repeated-turn invariants on macOS WKWebView**

```bash
flutter test integration_test/reader_pagination_test.dart -d macos --no-pub
```

Expected: I1/I4/I6 pass; `[792-TURN]` readback deltas stay approximately zero
and `firstCharTopVsInset` does not grow monotonically with page number.

- [ ] **Step 3: Capture the current result**

```bash
screencapture -x /tmp/hibiki-pagination-current-develop-20260713.png
```

Expected: no cumulative downward drift, no page-internal slant, and no adjacent-page band leak.

---

### Task 3: Branch only on evidence

**Files:**
- If no reproduction: update the existing report record `docs/bugs/BUG-405-pagination-cumulative-offset.md` with the current-develop retest and the later root-fix commits
- If reproduced: stop this verification plan and create a separately numbered recurrence record through `dart run tool/bug.dart new vertical-pagination-drift-recurrence "竖排翻页累积漂移在当前 develop 复发"`; the follow-up plan must use the exact path printed by that command

**Interfaces:**
- Consumes: Tasks 1-2 evidence
- Produces: an accurate bug-tracker outcome without speculative reader changes

- [ ] **Step 1: If current develop is stable, record verification only**

Append a dated retest note to BUG-405 explaining that the old report was later confirmed on the affected build and fixed by `5af42a348` plus `8add9d5e3`; record the focused tests and macOS screenshot. Run `dart run tool/bug.dart reindex` and commit documentation only.

- [ ] **Step 2: If current develop still drifts, capture runtime geometry before editing**

Record `body.getBoundingClientRect().height`, computed `columnWidth`, computed `columnGap`, parsed `columnCount`, `hoshiReader.pageSize`, `scrollTop`, and representative column-band top coordinates at page indices 1/10/20/30. The recurrence hypothesis is true only if actual whole-page period and `pageStep` diverge with an error that grows with page index.

- [ ] **Step 3: For a true recurrence, stop and write a separate root-fix plan**

Do not modify `reader_content_styles.dart` or `reader_pagination_scripts.dart` inside this verification plan. Create the new bug record and a focused design/implementation plan from the measured mismatch.
