# Test/CI Root-Fix Implementation Plan

> **For agentic workers:** root-cause fixes for the automated-testing audit (2026-05-30). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make CI actually execute the valuable tests that already exist and stop CI from silently misreporting coverage — attack the one root cause (tests↔CI disconnect + pseudo-coverage), not 37 symptoms.

**Architecture:** 4 structural fixes + 1 concrete high-severity coverage fill. Three are CI-config (verifiable by YAML parse + logic review, green confirmed only by a real CI run); two are locally verifiable by `flutter test` / `git`.

**Tech Stack:** GitHub Actions YAML, Flutter 3.41.6, Drift SQLite (hibiki_core), golden tests.

**Out of scope (explicit, NOT silently dropped):** writing the ~30 remaining missing test suites (AppModel/Profile behavioral, audiobook cue-sync integration, sync round-trip, import-UI path, dictionary FFI host harness) and standing up an Android-emulator integration job in CI. Those are a separate, larger test-authoring program tracked as follow-up in the audit report. This cycle fixes the *system* that hides them.

---

## Root-cause rationale

The audit found 37 confirmed gaps. Adversarial verification proved the "no coverage" framings were mostly false — the reader JS engine, hoshidicts FFI, and half the migration ladder **are** tested. The true root cause is singular: **those tests only run on a dev machine, and CI's package loop + gitignored goldens make the green check lie.** Fix the system, and the existing tests start earning their keep.

| Fix | Closes (audit findings) | Verifiable locally? |
|-----|-------------------------|---------------------|
| T1 Golden masters un-gitignore + commit | "golden masters gitignored → unverifiable in CI" (high) | ✅ `git check-ignore` + `flutter test test/goldens` |
| T2 hibiki_core downgrade migration test | "destructive downgrade untested" (high) + covers hibiki_core package | ✅ `flutter test` |
| T3 main.yml: develop trigger + visible package-loop | "develop = zero CI" (high), "package loop silent skip" (medium) | ⚠️ YAML parse only; green needs CI run |
| T4 build-multiplatform.yml: PR trigger + Windows job | "Windows never built" (high), "iOS/macOS/Linux not on PR" (high) | ⚠️ YAML parse only; green needs CI run |

---

## Task 1: Commit golden master images so golden tests are runnable in CI

**Files:**
- Modify: `hibiki/.gitignore:56` (the blanket `*.png`)
- Add (commit): `hibiki/test/goldens/golden_files/*.png` (37 masters)

- [ ] **Step 1: Verify masters match current code (must pass before committing them)**

Run: `cd hibiki && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test test/goldens`
Expected: PASS. If FAIL → masters are stale vs current widgets; STOP and report (do not commit a failing baseline).

- [ ] **Step 2: Narrow the gitignore so golden masters are tracked**

In `hibiki/.gitignore`, replace the bare `*.png` rule with a negation that re-includes the golden masters. Append immediately after line 56:

```gitignore
*.png
# Golden master baselines MUST be tracked or golden tests hard-fail in CI
# (matchesGoldenFile against a non-existent file). Generated diff artifacts
# under failures/ stay ignored.
!test/goldens/golden_files/
!test/goldens/golden_files/*.png
```

- [ ] **Step 3: Confirm masters are no longer ignored**

Run: `git check-ignore hibiki/test/goldens/golden_files/divider_dark.png; echo "exit=$?"`
Expected: no path printed, `exit=1` (not ignored).

- [ ] **Step 4: Stage + commit only the gitignore and the masters**

```bash
git add hibiki/.gitignore hibiki/test/goldens/golden_files/*.png
git commit -m "test(golden): track golden master baselines so CI can run them"
```

---

## Task 2: Add a CI-runnable destructive-downgrade migration test to hibiki_core

**Files:**
- Create: `packages/hibiki_core/test/migration_downgrade_test.dart`

Rationale: the `from > to` branch (database.dart:64-88) drops every table and recreates the schema. The file-backup half is gated on `_dbDirectory.isNotEmpty` and only reachable through the real `createInBackground` constructor (background isolate — not host-test-safe), so we test the destructive DROP+recreate via the in-memory `forTesting` path, which is exactly what runs in CI. This also gives `hibiki_core` a `test/` dir so the package loop (Task 3) stops skipping it.

- [ ] **Step 1: Write the test**

```dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// Regression guard for the destructive downgrade branch in
/// HibikiDatabase.migration (database.dart `if (from > to)`): when a DB stored
/// at a HIGHER schema version than the app's current schema (14) is opened,
/// the migration must DROP every table and recreate the current schema, never
/// leave the user on a future schema the app can't read.
///
/// The file-backup half (copy hibiki.db -> .bak before drop) is gated on a
/// non-empty _dbDirectory, only reachable via the real createInBackground
/// constructor (background isolate, not host-test-safe). This test covers the
/// destructive drop+recreate that runs in-process; the backup copy is covered
/// by code inspection (simple dart:io File.copy before the drop).
Future<HibikiDatabase> _openDowngradedFromV15() async {
  return HibikiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (rawDb) {
        // Seed a "future" DB: a stray table that does NOT exist in schema v14,
        // plus user_version=15 so Drift's onUpgrade fires with from(15) > to(14).
        rawDb.execute('PRAGMA user_version = 15');
        rawDb.execute(
          'CREATE TABLE future_only (id INTEGER PRIMARY KEY, junk TEXT)',
        );
        rawDb.execute("INSERT INTO future_only (junk) VALUES ('stale')");
      },
    ),
  );
}

void main() {
  test('downgrade from a future schema drops all tables and recreates v14',
      () async {
    final HibikiDatabase db = await _openDowngradedFromV15();
    addTearDown(db.close);

    // Force the lazy DB to open, triggering the migration.
    final version =
        await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 14,
        reason: 'downgrade must land on the app current schema version');

    // The future-only table must be gone (destructive drop ran).
    final futureTable = await db
        .customSelect(
          "SELECT name FROM sqlite_master "
          "WHERE type='table' AND name='future_only'",
        )
        .get();
    expect(futureTable, isEmpty,
        reason: 'stale future-only table must be dropped on downgrade');

    // A known v14 table must exist and be queryable (recreate ran).
    final epubCount = await db
        .customSelect('SELECT COUNT(*) AS c FROM epub_books')
        .getSingle();
    expect(epubCount.read<int>('c'), 0,
        reason: 'v14 schema must be recreated empty and queryable');
  });
}
```

- [ ] **Step 2: Run it (proves the migration branch and that hibiki_core now has tests)**

Run: `cd packages/hibiki_core && D:/flutter_sdk/flutter_extracted/flutter/bin/flutter.bat test`
Expected: PASS (1 test).

- [ ] **Step 3: Commit**

```bash
git add packages/hibiki_core/test/migration_downgrade_test.dart
git commit -m "test(core): cover destructive downgrade migration (drop+recreate to v14)"
```

---

## Task 3: Gate the active `develop` branch and make the package loop honest

**Files:**
- Modify: `.github/workflows/main.yml` (trigger block + "Run package tests" step)
- Modify: `.github/workflows/release.yml` ("Run package tests" step only)

- [ ] **Step 1: Add `develop` to main.yml triggers**

In `.github/workflows/main.yml`, change both branch filters from `['main']` to `['main', 'develop']`:

```yaml
on:
  push:
    branches: ['main', 'develop']
    paths: &ci_paths
      - 'hibiki/**'
      - 'packages/**'
      - 'ci/**'
      - '.github/workflows/**'
      - 'melos.yaml'
      - 'pubspec.yaml'
      - 'pubspec.lock'
  pull_request:
    branches: ['main', 'develop']
    paths: *ci_paths
  workflow_dispatch:
```

- [ ] **Step 2: Make the package-test loop surface missing tests instead of silently skipping**

In `.github/workflows/main.yml` and `.github/workflows/release.yml`, replace the `Run package tests` step body so a missing `test/` dir emits a visible GitHub warning annotation (non-blocking) instead of a silent skip:

```yaml
    - name: Run package tests
      run: |
        for pkg in packages/hibiki_core packages/hibiki_dictionary packages/hibiki_anki packages/hibiki_audio packages/hibiki_platform; do
          if [ -d "$pkg/test" ]; then
            echo "::group::Testing $pkg"
            (cd "$pkg" && flutter test)
            echo "::endgroup::"
          else
            echo "::warning title=No package tests::$pkg has no test/ dir — its code is only covered transitively by the main-app suite"
          fi
        done
```

- [ ] **Step 3: Validate YAML parses**

Run: `python -c "import yaml,sys; [yaml.safe_load(open(f)) for f in ['.github/workflows/main.yml','.github/workflows/release.yml']]; print('YAML OK')"`
Expected: `YAML OK`

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/main.yml .github/workflows/release.yml
git commit -m "ci: run pipeline on develop; surface packages missing tests instead of silent skip"
```

---

## Task 4: Verify all 5 platforms compile on PRs (add Windows; trigger on PR)

**Files:**
- Modify: `.github/workflows/build-multiplatform.yml` (trigger + add `windows` job)

- [ ] **Step 1: Broaden the trigger and add a Windows build job**

In `.github/workflows/build-multiplatform.yml`, change the `on:` block to also run on PRs to main/develop, and add a `windows` job mirroring the existing jobs:

```yaml
on:
  workflow_dispatch:
  push:
    branches: ['ci/**']
  pull_request:
    branches: ['main', 'develop']
```

Then add this job under `jobs:` (alongside `linux`, `macos`, `ios`):

```yaml
  windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.41.6'
      - name: Flutter pub get
        working-directory: hibiki
        run: flutter pub get
      - name: Apply pub cache patches
        shell: bash
        run: |
          chmod +x ci/apply-patches.sh
          bash ci/apply-patches.sh
      # Windows is the ONLY platform that renders EPUB via the forked
      # flutter_inappwebview_windows C++ plugin; a MSVC/native break here was
      # previously invisible to CI (audit: Windows never built).
      - name: Build Windows (debug)
        working-directory: hibiki
        run: >-
          flutter build windows --debug
          --dart-define=GOOGLE_OAUTH_CLIENT_ID=${{ secrets.GOOGLE_OAUTH_CLIENT_ID }}
          --dart-define=GOOGLE_OAUTH_CLIENT_SECRET=${{ secrets.GOOGLE_OAUTH_CLIENT_SECRET }}
```

- [ ] **Step 2: Validate YAML parses**

Run: `python -c "import yaml; yaml.safe_load(open('.github/workflows/build-multiplatform.yml')); print('YAML OK')"`
Expected: `YAML OK`

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-multiplatform.yml
git commit -m "ci: verify iOS/macOS/Linux/Windows builds on PRs; add Windows job"
```

---

## Task 5: Code review loop (REQUIRED, model: opus)

- [ ] **Step 1:** Dispatch code-reviewer subagent (`model: "opus"` per repo rule) over the full diff of Tasks 1–4.
- [ ] **Step 2:** Triage findings with `superpowers:receiving-code-review` (verify each before implementing).
- [ ] **Step 3:** Fix confirmed issues, re-run the relevant `flutter test` / YAML checks, amend/commit.
- [ ] **Step 4:** Re-review until no Critical/High remain.

---

## Self-review

- **Spec coverage:** T1→golden-gitignored (high); T2→downgrade-untested (high) + hibiki_core package coverage; T3→develop-zero-CI (high) + package-loop-silent (medium); T4→Windows-not-built (high) + multiplatform-not-on-PR (high). The other 30 findings are explicitly deferred above (no silent cap).
- **Placeholder scan:** every code/edit step shows literal content; no TBD/TODO.
- **Type consistency:** test uses `HibikiDatabase.forTesting(NativeDatabase.memory(...))` exactly as the existing `srt_cue_migration_test.dart`; `customSelect(...).getSingle()/.get()` + `read<int>` match existing usage.
- **Concurrency:** a second agent shares this working tree on `develop` — each task stages only its own files (never `git add -A`).
