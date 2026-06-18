# Hibiki specs index

This folder contains dated design notes, implementation plans, and handoff records. Most files are historical snapshots: read them as context for why a feature moved in a certain direction, then verify the current behavior in code before implementing new changes.

For agent operating rules, build rules, and verification gates, use `../agent/` instead. For open bug records, use `../BUGS.md` and `../bugs/`.

## How to Use This Folder

- Start from the newest matching topic when you need current product intent.
- Prefer `*-design.md` for product and architecture decisions.
- Prefer `*-plan.md` for implementation steps and verification notes.
- Treat `*-handoff.md`, `*-rootfix.md`, and `*-roadmap.md` as transition records, not standing rules.
- When a design and a plan share the same date and slug, read the design first, then the plan.

## Current Topic Map

| Area | Start here | Also useful |
| --- | --- | --- |
| Reader layout and settings | [2026-06-06-reader-settings-master-detail.md](2026-06-06-reader-settings-master-detail.md), [2026-06-04-reader-appearance-merge-and-audio-volume-persist-plan.md](2026-06-04-reader-appearance-merge-and-audio-volume-persist-plan.md) | [2026-05-25-in-book-reader-settings-design.md](2026-05-25-in-book-reader-settings-design.md), [2026-05-29-reader-layout-rootfix.md](2026-05-29-reader-layout-rootfix.md) |
| Reader focus, navigation, and lookup | [2026-06-04-reader-focus-surface-fixes-plan.md](2026-06-04-reader-focus-surface-fixes-plan.md), [2026-06-07-dictionary-popup-unification-plan.md](2026-06-07-dictionary-popup-unification-plan.md) | [2026-05-30-reader-char-caret-navigation-design.md](2026-05-30-reader-char-caret-navigation-design.md), [2026-05-30-reader-char-caret-navigation-plan.md](2026-05-30-reader-char-caret-navigation-plan.md) |
| Video and subtitle mining | [2026-06-05-video-subsystem-plan.md](2026-06-05-video-subsystem-plan.md), [2026-06-07-video-ass-markup-design.md](2026-06-07-video-ass-markup-design.md) | [2026-06-06-video-statistics-design.md](2026-06-06-video-statistics-design.md), [2026-06-06-video-statistics-plan.md](2026-06-06-video-statistics-plan.md), [2026-06-04-video-mining-design.md](2026-06-04-video-mining-design.md) |
| Audio, subtitles, and Sasayaki | [2026-06-04-merge-audio-sources-design.md](2026-06-04-merge-audio-sources-design.md), [2026-06-04-merge-audio-sources-plan.md](2026-06-04-merge-audio-sources-plan.md) | [2026-06-05-audiobook-highlight-seek-space-plan.md](2026-06-05-audiobook-highlight-seek-space-plan.md), [2026-06-02-unified-audio-sources-design.md](2026-06-02-unified-audio-sources-design.md), [2026-06-02-unified-audio-sources-plan.md](2026-06-02-unified-audio-sources-plan.md) |
| Sync, backup, and Interconnect | [2026-06-08-interconnect-live-library-sync-plan.md](2026-06-08-interconnect-live-library-sync-plan.md), [2026-06-08-interconnect-live-library-phase2-4-plan.md](2026-06-08-interconnect-live-library-phase2-4-plan.md) | [2026-06-05-sync-content-hash-manifest-design.md](2026-06-05-sync-content-hash-manifest-design.md), [2026-05-30-sync-backup-config-redesign-design.md](2026-05-30-sync-backup-config-redesign-design.md), [2026-05-30-sync-backup-config-redesign-plan.md](2026-05-30-sync-backup-config-redesign-plan.md) |
| Import, files, and book identity | [2026-06-06-drag-drop-import-design.md](2026-06-06-drag-drop-import-design.md), [2026-06-06-drag-drop-import-plan.md](2026-06-06-drag-drop-import-plan.md) | [2026-06-05-book-identity-name-key-design.md](2026-06-05-book-identity-name-key-design.md), [2026-06-05-book-identity-name-key-plan.md](2026-06-05-book-identity-name-key-plan.md), [2026-06-05-zip64-central-directory-import-plan.md](2026-06-05-zip64-central-directory-import-plan.md) |
| Desktop, browser bridge, and clipboard | [2026-06-05-webext-and-desktop-clipboard-design.md](2026-06-05-webext-and-desktop-clipboard-design.md), [2026-06-05-webext-plan.md](2026-06-05-webext-plan.md) | [2026-06-04-browser-extension-bridge-design.md](2026-06-04-browser-extension-bridge-design.md), [2026-06-04-browser-extension-bridge-plan.md](2026-06-04-browser-extension-bridge-plan.md), [2026-06-05-desktop-clipboard-plan.md](2026-06-05-desktop-clipboard-plan.md) |
| Anki and card creation | [2026-06-05-anki-lapis-one-click-design.md](2026-06-05-anki-lapis-one-click-design.md), [2026-06-05-anki-lapis-one-click-plan.md](2026-06-05-anki-lapis-one-click-plan.md) | [2026-06-05-lyrics-mode-focus-lookup-design.md](2026-06-05-lyrics-mode-focus-lookup-design.md), [2026-06-05-lyrics-mode-focus-lookup-plan.md](2026-06-05-lyrics-mode-focus-lookup-plan.md) |
| UI architecture and adaptive shell | [2026-06-03-md3-adaptive-nav-shell-plan.md](2026-06-03-md3-adaptive-nav-shell-plan.md), [2026-06-02-desktop-shell-md3-roadmap.md](2026-06-02-desktop-shell-md3-roadmap.md) | [2026-06-02-desktop-settings-md3-design.md](2026-06-02-desktop-settings-md3-design.md), [2026-06-02-desktop-settings-md3-plan.md](2026-06-02-desktop-settings-md3-plan.md), [../design/md3-cupertino/README.md](../design/md3-cupertino/README.md) |
| Testing, CI, and builds | [2026-06-03-test-flow-refactor-design.md](2026-06-03-test-flow-refactor-design.md), [2026-06-03-test-flow-refactor-plan.md](2026-06-03-test-flow-refactor-plan.md) | [2026-06-01-comprehensive-test-automation-plan.md](2026-06-01-comprehensive-test-automation-plan.md), [2026-05-30-five-platform-build.md](2026-05-30-five-platform-build.md), [2026-05-30-test-ci-rootfix.md](2026-05-30-test-ci-rootfix.md) |

## Naming Guide

| Suffix | Meaning |
| --- | --- |
| `*-design.md` | Product behavior, UX shape, architecture, or data model decisions. |
| `*-plan.md` | Implementation steps, sequencing, risk notes, and verification commands. |
| `*-roadmap.md` | Multi-phase direction that may span several follow-up files. |
| `*-rootfix.md` | Root-cause notes for a fixed class of bugs. |
| `*-handoff.md` | Handoff state from one implementation session to another. |

## Maintenance Notes

- Add new specs with a `YYYY-MM-DD-slug-{design|plan}.md` name when possible.
- Keep one topic per file; add a second plan file instead of turning a finished plan into a rolling log.
- Link related design and plan files at the top of each new document.
- Do not move or rewrite old files just to tidy the archive; update this index when a newer document supersedes an older one.
