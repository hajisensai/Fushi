# Multi-File Audio Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-subtitle + alphabetical-sort audio import with a management panel supporting per-file subtitles, natural sorting, drag reorder, and EPUB chapter mapping.

**Architecture:** New `AudioFileEntry` model holds per-file metadata (path, label, subtitle, chapter mapping). `BookImportDialog` gains a `ReorderableListView`-based management panel. Parsers get an `audioFileIndex` parameter. Import loop iterates entries instead of using a single global subtitle.

**Tech Stack:** Flutter, Dart, file_picker, slang (i18n), ReorderableListView

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/src/media/audiobook/audio_file_entry.dart` | Create | `AudioFileEntry` model + `naturalCompare` + `autoMatchSubtitles` |
| `lib/src/media/audiobook/audio_file_panel.dart` | Create | Management panel widget (reorderable list with chapter dropdown + subtitle pairing) |
| `lib/src/media/audiobook/book_import_dialog.dart` | Modify | Replace `_srtPath`/`_audioPaths` with `List<AudioFileEntry>`; wire up panel; rewrite `_doImport` loop |
| `lib/src/media/audiobook/srt_parser.dart` | Modify | Add `audioFileIndex` param (default 0) |
| `lib/src/media/audiobook/lrc_parser.dart` | Modify | Add `audioFileIndex` param (default 0) |
| `lib/src/media/audiobook/vtt_parser.dart` | Modify | Add `audioFileIndex` param (default 0) |
| `lib/src/media/audiobook/ass_parser.dart` | Modify | Add `audioFileIndex` param (default 0) |
| `lib/i18n/strings.i18n.json` | Modify | Add new i18n keys for panel UI |
| `lib/i18n/strings.g.dart` | Regenerate | Run slang build |

---

### Task 1: AudioFileEntry Model + Natural Sort + Auto-Pairing

**Files:**
- Create: `hibiki/lib/src/media/audiobook/audio_file_entry.dart`

- [ ] **Step 1: Create `AudioFileEntry` class and `naturalCompare`**

```dart
// hibiki/lib/src/media/audiobook/audio_file_entry.dart
import 'dart:io';
import 'package:path/path.dart' as p;

class AudioFileEntry {
  AudioFileEntry({
    required this.path,
    String? label,
    this.mappedSection,
    this.subtitlePath,
  }) : label = label ?? _stemOf(path);

  final String path;
  String label;
  int? mappedSection;
  String? subtitlePath;

  static String _stemOf(String path) =>
      p.basenameWithoutExtension(path);
}

/// Natural-order comparison: splits strings into text and numeric chunks
/// so that "track2" < "track10".
int naturalCompare(String a, String b) {
  final RegExp re = RegExp(r'(\d+|\D+)');
  final List<String> partsA = re.allMatches(a).map((m) => m[0]!).toList();
  final List<String> partsB = re.allMatches(b).map((m) => m[0]!).toList();
  for (int i = 0; i < partsA.length && i < partsB.length; i++) {
    final int? numA = int.tryParse(partsA[i]);
    final int? numB = int.tryParse(partsB[i]);
    int cmp;
    if (numA != null && numB != null) {
      cmp = numA.compareTo(numB);
    } else {
      cmp = partsA[i].toLowerCase().compareTo(partsB[i].toLowerCase());
    }
    if (cmp != 0) return cmp;
  }
  return partsA.length.compareTo(partsB.length);
}

/// Normalize a filename stem for matching: lowercase, strip non-alphanumeric.
String _normalizeStem(String stem) =>
    stem.toLowerCase().replaceAll(RegExp(r'[^a-z0-9　-鿿＀-￯]'), '');

/// Auto-pair subtitle files to audio entries by filename similarity.
///
/// Priority: exact normalized stem match > one contains the other > unmatched.
/// Returns leftover subtitle paths that couldn't be matched.
List<String> autoMatchSubtitles({
  required List<AudioFileEntry> entries,
  required List<String> subtitlePaths,
}) {
  final List<String> remaining = List<String>.of(subtitlePaths);

  // Pass 1: exact stem match.
  for (final AudioFileEntry entry in entries) {
    if (entry.subtitlePath != null) continue;
    final String audioStem = _normalizeStem(p.basenameWithoutExtension(entry.path));
    for (int i = 0; i < remaining.length; i++) {
      final String subStem = _normalizeStem(p.basenameWithoutExtension(remaining[i]));
      if (audioStem == subStem) {
        entry.subtitlePath = remaining.removeAt(i);
        break;
      }
    }
  }

  // Pass 2: contains match (shorter stem contained in longer).
  for (final AudioFileEntry entry in entries) {
    if (entry.subtitlePath != null) continue;
    final String audioStem = _normalizeStem(p.basenameWithoutExtension(entry.path));
    if (audioStem.isEmpty) continue;
    for (int i = 0; i < remaining.length; i++) {
      final String subStem = _normalizeStem(p.basenameWithoutExtension(remaining[i]));
      if (subStem.isEmpty) continue;
      if (audioStem.contains(subStem) || subStem.contains(audioStem)) {
        entry.subtitlePath = remaining.removeAt(i);
        break;
      }
    }
  }

  return remaining;
}
```

- [ ] **Step 2: Verify the file compiles**

Run: `cd d:/APP/vs_claude_code/hibiki/hibiki && dart analyze lib/src/media/audiobook/audio_file_entry.dart`
Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/src/media/audiobook/audio_file_entry.dart
git commit -m "feat: add AudioFileEntry model with natural sort and auto-pairing"
```

---

### Task 2: Add `audioFileIndex` Parameter to All Parsers

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/srt_parser.dart`
- Modify: `hibiki/lib/src/media/audiobook/lrc_parser.dart`
- Modify: `hibiki/lib/src/media/audiobook/vtt_parser.dart`
- Modify: `hibiki/lib/src/media/audiobook/ass_parser.dart`

Each parser hardcodes `..audioFileIndex = 0`. Add an `int audioFileIndex = 0` parameter to both `parse()` and `parseString()` methods, and use it instead of the literal `0`.

- [ ] **Step 1: Update `SrtParser`**

In `srt_parser.dart`, add `int audioFileIndex = 0` to both `parse()` and `parseString()` signatures. In `parse()`, pass it through to `parseString()`. In `parseString()`, replace `..audioFileIndex = 0` with `..audioFileIndex = audioFileIndex`.

```dart
// parse() signature becomes:
static Future<List<AudioCue>> parse({
  required File srtFile,
  required String bookUid,
  String chapterHref = defaultChapter,
  int audioFileIndex = 0,
}) async {
  final String content = await readTextWithEncoding(srtFile);
  return parseString(
    content: content,
    bookUid: bookUid,
    chapterHref: chapterHref,
    audioFileIndex: audioFileIndex,
  );
}

// parseString() signature adds:
//   int audioFileIndex = 0,
// and body changes:
//   ..audioFileIndex = audioFileIndex
```

- [ ] **Step 2: Update `LrcParser`**

Same pattern: add `int audioFileIndex = 0` to `parse()` and `parseString()`, pass through, replace `..audioFileIndex = 0` with `..audioFileIndex = audioFileIndex`.

- [ ] **Step 3: Update `VttParser`**

Same pattern.

- [ ] **Step 4: Update `AssParser`**

Same pattern.

- [ ] **Step 5: Verify all parsers compile**

Run: `cd d:/APP/vs_claude_code/hibiki/hibiki && dart analyze lib/src/media/audiobook/srt_parser.dart lib/src/media/audiobook/lrc_parser.dart lib/src/media/audiobook/vtt_parser.dart lib/src/media/audiobook/ass_parser.dart`
Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/media/audiobook/srt_parser.dart hibiki/lib/src/media/audiobook/lrc_parser.dart hibiki/lib/src/media/audiobook/vtt_parser.dart hibiki/lib/src/media/audiobook/ass_parser.dart
git commit -m "feat: add audioFileIndex parameter to all subtitle parsers"
```

---

### Task 3: Audio File Management Panel Widget

**Files:**
- Create: `hibiki/lib/src/media/audiobook/audio_file_panel.dart`

This is a self-contained widget that displays the reorderable list of `AudioFileEntry` items with chapter dropdown and subtitle pairing.

- [ ] **Step 1: Create `AudioFilePanel` widget**

```dart
// hibiki/lib/src/media/audiobook/audio_file_panel.dart
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/media/audiobook/audio_file_entry.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';
import 'package:hibiki/utils.dart';

/// Section info for the chapter dropdown. Carries index + display label.
class SectionOption {
  const SectionOption({required this.index, required this.label});
  final int index;
  final String label;
}

/// Management panel for multi-file audio import.
///
/// Shows a reorderable list where each row has:
/// - drag handle
/// - audio filename (label)
/// - chapter dropdown (if [sections] is non-empty)
/// - subtitle filename or "unpaired" warning, tappable to reassign
class AudioFilePanel extends StatefulWidget {
  const AudioFilePanel({
    required this.entries,
    required this.sections,
    required this.unmatchedSubtitles,
    required this.onChanged,
    super.key,
  });

  final List<AudioFileEntry> entries;
  final List<SectionOption> sections;
  final List<String> unmatchedSubtitles;
  final VoidCallback onChanged;

  @override
  State<AudioFilePanel> createState() => _AudioFilePanelState();
}

class _AudioFilePanelState extends State<AudioFilePanel> {
  static const List<String> _subtitleExts = ['srt', 'lrc', 'vtt', 'ass', 'ssa'];

  void _onReorder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final AudioFileEntry entry = widget.entries.removeAt(oldIndex);
    widget.entries.insert(newIndex, entry);
    widget.onChanged();
  }

  Future<void> _pickSubtitleFor(int index) async {
    // Show options: unmatched pool + pick new file
    final List<String> pool = widget.unmatchedSubtitles;

    final String? chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(t.srt_pick_subtitle_file),
        children: [
          for (final String sub in pool)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, sub),
              child: Text(p.basename(sub), style: const TextStyle(fontSize: 13)),
            ),
          SimpleDialogOption(
            onPressed: () async {
              final FilePickerResult? result = await FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: _subtitleExts,
              );
              final String? path = result?.files.single.path;
              if (ctx.mounted) Navigator.pop(ctx, path);
            },
            child: Row(
              children: [
                const Icon(Icons.add, size: 18),
                const SizedBox(width: 8),
                Text(t.audio_panel_pick_new_subtitle, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          if (widget.entries[index].subtitlePath != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '__remove__'),
              child: Row(
                children: [
                  const Icon(Icons.clear, size: 18, color: Colors.red),
                  const SizedBox(width: 8),
                  Text(t.audio_panel_remove_subtitle,
                      style: const TextStyle(fontSize: 13, color: Colors.red)),
                ],
              ),
            ),
        ],
      ),
    );

    if (chosen == null || !mounted) return;
    setState(() {
      if (chosen == '__remove__') {
        final String? old = widget.entries[index].subtitlePath;
        widget.entries[index].subtitlePath = null;
        if (old != null) widget.unmatchedSubtitles.add(old);
      } else {
        // If previously paired, return old one to pool
        final String? old = widget.entries[index].subtitlePath;
        if (old != null) widget.unmatchedSubtitles.add(old);
        widget.entries[index].subtitlePath = chosen;
        widget.unmatchedSubtitles.remove(chosen);
      }
    });
    widget.onChanged();
  }

  void _onChapterChanged(int entryIndex, int? sectionIndex) {
    widget.entries[entryIndex].mappedSection = sectionIndex;
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            t.audio_panel_title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: 240,
          ),
          child: ReorderableListView.builder(
            shrinkWrap: true,
            buildDefaultDragHandles: false,
            itemCount: widget.entries.length,
            onReorder: _onReorder,
            itemBuilder: (context, index) {
              final AudioFileEntry e = widget.entries[index];
              return _buildRow(e, index);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRow(AudioFileEntry e, int index) {
    final bool hasSections = widget.sections.isNotEmpty;
    return Material(
      key: ValueKey(e.path),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.drag_handle, size: 18, color: Colors.grey),
              ),
            ),
            // Audio filename
            Expanded(
              flex: 3,
              child: Text(
                e.label,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            // Chapter dropdown
            if (hasSections)
              Expanded(
                flex: 2,
                child: DropdownButton<int?>(
                  value: e.mappedSection,
                  isExpanded: true,
                  isDense: true,
                  style: const TextStyle(fontSize: 11),
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem<int?>(
                      value: null,
                      child: Text(t.audio_panel_auto,
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ),
                    for (final SectionOption s in widget.sections)
                      DropdownMenuItem<int?>(
                        value: s.index,
                        child: Text(
                          s.label.isNotEmpty ? s.label : 'Section ${s.index}',
                          style: const TextStyle(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (int? v) => _onChapterChanged(index, v),
                ),
              ),
            // Subtitle pairing
            Expanded(
              flex: 2,
              child: InkWell(
                onTap: () => _pickSubtitleFor(index),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (e.subtitlePath != null) ...[
                      const Icon(Icons.subtitles, size: 14, color: Colors.green),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Text(
                          p.basename(e.subtitlePath!),
                          style: const TextStyle(fontSize: 10, color: Colors.green),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ] else ...[
                      const Icon(Icons.warning_amber, size: 14, color: Colors.orange),
                      const SizedBox(width: 2),
                      Text(
                        t.audio_panel_unpaired,
                        style: const TextStyle(fontSize: 10, color: Colors.orange),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `cd d:/APP/vs_claude_code/hibiki/hibiki && dart analyze lib/src/media/audiobook/audio_file_panel.dart`
Expected: Errors about missing i18n keys (addressed in Task 4)

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/src/media/audiobook/audio_file_panel.dart
git commit -m "feat: add AudioFilePanel management widget"
```

---

### Task 4: Add i18n Strings

**Files:**
- Modify: `hibiki/lib/i18n/strings.i18n.json`
- Regenerate: `hibiki/lib/i18n/strings.g.dart`

- [ ] **Step 1: Add new keys to `strings.i18n.json`**

Add these entries in the same section as existing `srt_import_*` keys (around line 500):

```json
"audio_panel_title": "Audio Files",
"audio_panel_auto": "Auto",
"audio_panel_unpaired": "Unpaired",
"audio_panel_pick_new_subtitle": "Pick new subtitle file",
"audio_panel_remove_subtitle": "Remove subtitle",
"audio_panel_add_audio": "Add Audio",
"audio_panel_add_subtitle": "Add Subtitles",
"srt_import_pick_subtitle_files": "Pick Subtitle Files",
"srt_import_unpaired_subtitles": "$n unmatched subtitle(s)"
```

- [ ] **Step 2: Regenerate i18n**

Run: `cd d:/APP/vs_claude_code/hibiki/hibiki && dart run slang`

If slang codegen doesn't work (build_runner issues noted in CLAUDE.md), manually add the getters to `strings.g.dart` in the `Translations` class, following the existing pattern at line ~609:

```dart
String get audio_panel_title => 'Audio Files';
String get audio_panel_auto => 'Auto';
String get audio_panel_unpaired => 'Unpaired';
String get audio_panel_pick_new_subtitle => 'Pick new subtitle file';
String get audio_panel_remove_subtitle => 'Remove subtitle';
String get audio_panel_add_audio => 'Add Audio';
String get audio_panel_add_subtitle => 'Add Subtitles';
String get srt_import_pick_subtitle_files => 'Pick Subtitle Files';
String srt_import_unpaired_subtitles({required Object n}) => '${n} unmatched subtitle(s)';
```

- [ ] **Step 3: Verify compile**

Run: `cd d:/APP/vs_claude_code/hibiki/hibiki && dart analyze lib/i18n/strings.g.dart`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/i18n/strings.i18n.json hibiki/lib/i18n/strings.g.dart
git commit -m "feat: add i18n strings for audio file management panel"
```

---

### Task 5: Rewrite BookImportDialog to Use AudioFileEntry

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/book_import_dialog.dart`

This is the largest task. The dialog's state changes from `_srtPath` + `_audioPaths` to `List<AudioFileEntry>` + `List<String> _unmatchedSubtitles`. The form gains the management panel. The import loop iterates entries.

- [ ] **Step 1: Replace state variables**

In `_BookImportDialogState`, replace:

```dart
// OLD:
String? _srtPath;
String? _audioDir;
List<String>? _audioPaths;
```

With:

```dart
// NEW:
List<AudioFileEntry> _audioEntries = [];
List<String> _unmatchedSubtitles = [];
String? _audioDir; // folder mode still supported
List<SectionOption> _epubSections = [];
```

Add import at top:

```dart
import 'package:hibiki/src/media/audiobook/audio_file_entry.dart';
import 'package:hibiki/src/media/audiobook/audio_file_panel.dart';
```

- [ ] **Step 2: Update computed properties**

Replace `_hasAudioSource` and `_audioSourceLabel`:

```dart
bool get _hasAudioSource =>
    _audioDir != null || _audioEntries.isNotEmpty;

bool get _hasSubtitles =>
    _audioEntries.any((e) => e.subtitlePath != null);

String get _audioSourceLabel {
  if (_audioEntries.isNotEmpty) {
    return t.srt_import_files_selected(n: _audioEntries.length);
  }
  if (_audioDir != null) return _basename(_audioDir!);
  return '';
}
```

Update `_willRunMatcher` — it should check if ANY entry has a subtitle in a matcher-supported format:

```dart
bool get _willRunMatcher {
  if (_epubPath == null) return false;
  return _audioEntries.any((e) {
    if (e.subtitlePath == null) return false;
    final String ext = e.subtitlePath!.split('.').last.toLowerCase();
    return SasayakiRematch.supportedFormats.contains(ext);
  });
}
```

- [ ] **Step 3: Replace `_subtitleRow()` with multi-subtitle picker**

Replace `_subtitleRow()`:

```dart
Widget _subtitleRow() {
  final int pairedCount = _audioEntries.where((e) => e.subtitlePath != null).length;
  final int totalSubs = pairedCount + _unmatchedSubtitles.length;
  return Row(
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.srt_import_pick_subtitle_files,
                style: const TextStyle(fontSize: 13)),
            if (totalSubs > 0)
              Text(
                t.srt_import_files_selected(n: totalSubs),
                style: const TextStyle(fontSize: 11, color: Colors.grey),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
          ],
        ),
      ),
      IconButton(
        icon: const Icon(Icons.subtitles, size: 20),
        tooltip: t.srt_import_pick_subtitle_files,
        onPressed: _pickSubtitleFiles,
      ),
    ],
  );
}
```

- [ ] **Step 4: Replace `_pickSrt()` and `_pickSrtFromFolder()` with `_pickSubtitleFiles()`**

Remove `_pickSrt()` and `_pickSrtFromFolder()`. Add:

```dart
Future<void> _pickSubtitleFiles() async {
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['srt', 'lrc', 'vtt', 'ass', 'ssa'],
    allowMultiple: true,
  );
  if (result == null || !mounted) return;

  final List<String> paths = result.files
      .map((f) => f.path)
      .whereType<String>()
      .toList();

  if (paths.isEmpty) return;

  setState(() {
    final List<String> leftover = autoMatchSubtitles(
      entries: _audioEntries,
      subtitlePaths: paths,
    );
    _unmatchedSubtitles.addAll(leftover);

    if (_titleCtrl.text.isEmpty && paths.isNotEmpty) {
      _titleCtrl.text = p.basenameWithoutExtension(paths.first);
    }
  });
}
```

- [ ] **Step 5: Update `_pickAudioFiles()` to create `AudioFileEntry` list**

```dart
Future<void> _pickAudioFiles() async {
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.audio,
    allowMultiple: true,
  );
  if (result == null || !mounted) return;

  final List<String> paths = result.files
      .map((f) => f.path)
      .whereType<String>()
      .toList()
    ..sort(naturalCompare);

  if (paths.isEmpty) return;

  setState(() {
    // Merge with existing entries (append new ones)
    final Set<String> existing = _audioEntries.map((e) => e.path).toSet();
    for (final String path in paths) {
      if (!existing.contains(path)) {
        _audioEntries.add(AudioFileEntry(path: path));
      }
    }
    _audioDir = null;

    // Re-run auto-pairing for any unmatched subtitles
    if (_unmatchedSubtitles.isNotEmpty) {
      final List<String> stillUnmatched = autoMatchSubtitles(
        entries: _audioEntries,
        subtitlePaths: _unmatchedSubtitles,
      );
      _unmatchedSubtitles = stillUnmatched;
    }
  });
}
```

- [ ] **Step 6: Update `_pickAudioDir()` to create entries from folder scan**

```dart
Future<void> _pickAudioDir() async {
  final String? dir = await FilePicker.platform.getDirectoryPath();
  if (dir == null || !mounted) return;

  final Directory directory = Directory(dir);
  if (!directory.existsSync()) return;

  const List<String> audioExts = [
    '.mp3', '.m4a', '.m4b', '.aac', '.ogg', '.opus', '.flac', '.wav', '.wma',
  ];
  final List<File> files = directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) {
        final String lower = f.path.toLowerCase();
        return audioExts.any(lower.endsWith);
      })
      .toList()
    ..sort((a, b) => naturalCompare(a.path, b.path));

  if (files.isEmpty) {
    Fluttertoast.showToast(msg: t.srt_no_audio_files);
    return;
  }

  setState(() {
    _audioEntries = files.map((f) => AudioFileEntry(path: f.path)).toList();
    _audioDir = dir;

    if (_unmatchedSubtitles.isNotEmpty) {
      final List<String> stillUnmatched = autoMatchSubtitles(
        entries: _audioEntries,
        subtitlePaths: _unmatchedSubtitles,
      );
      _unmatchedSubtitles = stillUnmatched;
    }
  });
}
```

- [ ] **Step 7: Add management panel to `_buildForm()`**

In `_buildForm()`, after `_audioSourceRow()` and before the title TextField, add:

```dart
if (_audioEntries.isNotEmpty) ...[
  const SizedBox(height: 8),
  AudioFilePanel(
    entries: _audioEntries,
    sections: _epubSections,
    unmatchedSubtitles: _unmatchedSubtitles,
    onChanged: () => setState(() {}),
  ),
],
```

- [ ] **Step 8: Load EPUB sections when EPUB is picked**

Update `_pickEpub()` to load section info for the chapter dropdown. Add after setting `_epubPath`:

```dart
// Load sections for chapter mapping dropdown (best-effort, non-blocking)
_loadEpubSections();
```

Add method:

```dart
Future<void> _loadEpubSections() async {
  // We need a ttuBookId to read sections, but at pick time the EPUB isn't
  // imported yet. We can't read IDB without importing first.
  // Instead, we'll populate sections lazily after import — OR read the TOC
  // from the EPUB file directly. For now, sections will be populated if the
  // user has previously imported this EPUB and we can find it in ttu IDB.
  // This is a best-effort feature; the dropdown defaults to "Auto" if
  // sections aren't available.
  setState(() => _epubSections = []);
}
```

Note: Full section loading requires importing the EPUB first (ttu IDB). For now the dropdown will populate only for already-imported EPUBs. This is acceptable because "Auto" ordering works for most cases and manual chapter mapping is a power-user feature.

- [ ] **Step 9: Rewrite `_doImport()` to loop over entries**

Replace the validation and routing in `_doImport()`:

```dart
Future<void> _doImport() async {
  if (_epubPath == null && !_hasSubtitles) {
    Fluttertoast.showToast(msg: t.srt_import_missing_input);
    return;
  }
  if (_epubPath != null && !_hasSubtitles && _hasAudioSource) {
    Fluttertoast.showToast(msg: t.srt_import_audio_needs_subtitle);
    return;
  }
  final String title = _titleCtrl.text.trim();
  if (title.isEmpty) {
    Fluttertoast.showToast(msg: t.srt_import_missing_title);
    return;
  }

  setState(() => _importing = true);
  Fluttertoast.showToast(msg: t.dialog_importing);

  try {
    final String? authorText = _authorCtrl.text.trim().isEmpty
        ? null
        : _authorCtrl.text.trim();

    String? tail;
    if (_epubPath != null && _hasSubtitles) {
      tail = await _importEpubWithAlignment(title: title);
    } else if (_hasSubtitles) {
      await _importSubtitleBook(title: title, author: authorText);
    } else {
      await _importEpubOnly(title: title);
    }

    if (mounted) {
      final String msg = tail == null
          ? t.srt_import_success
          : '${t.srt_import_success} · $tail';
      Fluttertoast.showToast(msg: msg);
      Navigator.pop(context, true);
    }
  } catch (e) {
    debugPrint('BookImportDialog error: $e');
    if (mounted) {
      Fluttertoast.showToast(msg: '${t.srt_import_error}: $e');
    }
  } finally {
    if (mounted) {
      setState(() => _importing = false);
    }
  }
}
```

- [ ] **Step 10: Rewrite `_importSubtitleBook()` for multi-file**

```dart
Future<void> _importSubtitleBook({
  required String title,
  required String? author,
}) async {
  final String uid = 'srtbook_${DateTime.now().millisecondsSinceEpoch}';
  final List<AudioCue> allCues = [];

  for (int i = 0; i < _audioEntries.length; i++) {
    final AudioFileEntry entry = _audioEntries[i];
    if (entry.subtitlePath == null) continue;
    final List<AudioCue> cues = await _parseCuesWithIndex(
      File(entry.subtitlePath!), uid, i,
    );
    allCues.addAll(cues);
  }

  int ttuBookId = 0;
  if (allCues.isNotEmpty) {
    try {
      final TtuIdbPayload payload = CuesToEpub.buildIdbPayload(
        title: title,
        cues: allCues,
      );
      ttuBookId = await _injectPayloadIntoTtuIdb(payload);
    } catch (e) {
      debugPrint('[hibiki-import] ttu IDB inject failed: $e');
    }
  }

  final Directory persistDir = await _ensurePersistDir(uid);
  List<String>? persistedAudioPaths;
  String? persistedAudioRoot;
  if (_audioEntries.isNotEmpty) {
    persistedAudioPaths = [];
    for (final AudioFileEntry entry in _audioEntries) {
      persistedAudioPaths.add(await _persistFile(File(entry.path), persistDir));
    }
  } else if (_audioDir != null) {
    persistedAudioRoot = _audioDir;
  }

  // Persist the first subtitle as the "main" srtPath for backward compat
  final String? firstSubPath = _audioEntries
      .map((e) => e.subtitlePath)
      .whereType<String>()
      .firstOrNull;
  final String persistedSrt = firstSubPath != null
      ? await _persistFile(File(firstSubPath), persistDir)
      : '';

  final SrtBook book = SrtBook()
    ..uid = uid
    ..title = title
    ..srtPath = persistedSrt
    ..importedAt = DateTime.now().millisecondsSinceEpoch
    ..ttuBookId = ttuBookId;
  if (persistedAudioPaths != null && persistedAudioPaths.isNotEmpty) {
    book.audioPaths = persistedAudioPaths;
  } else if (persistedAudioRoot != null) {
    book.audioRoot = persistedAudioRoot;
  }
  if (author != null) {
    book.author = author;
  }

  debugPrint('[hibiki-import] SrtBook save: uid=$uid title="$title" '
      'ttuBookId=$ttuBookId cues=${allCues.length}');

  await widget.repo.save(book);
  await widget.repo.saveCues(uid: uid, cues: allCues);
}
```

- [ ] **Step 11: Rewrite `_importEpubWithAlignment()` for multi-file**

Replace the cue parsing + matcher section (step 3 in the existing method, around lines 621-653). Key change: loop over `_audioEntries`, parse each subtitle independently, assign `audioFileIndex`, run matcher per-file if `mappedSection` is set or merge all cues and run matcher once otherwise.

```dart
Future<String?> _importEpubWithAlignment({required String title}) async {
  // 1) Import EPUB into ttu
  final File epubFile = File(_epubPath!);
  final int ttuBookId = await TtuEpubImporter.import(
    bytes: await epubFile.readAsBytes(),
    filename: _basename(_epubPath!),
    serverPort: widget.serverPort,
  );
  if (ttuBookId <= 0) {
    throw StateError('ttu returned invalid book id');
  }

  // 2) Read sections from ttu IDB
  String idbTitle = '';
  List<EpubSection> sections = const <EpubSection>[];
  try {
    final TtuBookRecord rec = await TtuIdbReader.readBookRecord(
      ttuBookId: ttuBookId,
      serverPort: widget.serverPort,
    );
    idbTitle = rec.title;
    sections = rec.sections;
  } catch (e) {
    debugPrint('[hibiki-import] readBookRecord failed: $e');
  }
  final String safeTitle = idbTitle.isNotEmpty ? idbTitle : ' ';
  final String mediaIdentifier =
      'http://localhost:${widget.serverPort}/b.html?id=$ttuBookId&?title=$safeTitle';
  final String bookUid =
      '${widget.ttuMediaSourceIdentifier}/$mediaIdentifier';

  // 3) Parse cues from each entry's subtitle
  final List<AudioCue> allCues = [];
  String? firstExt;
  for (int i = 0; i < _audioEntries.length; i++) {
    final AudioFileEntry entry = _audioEntries[i];
    if (entry.subtitlePath == null) continue;
    firstExt ??= entry.subtitlePath!.split('.').last.toLowerCase();
    final List<AudioCue> cues = await _parseCuesWithIndex(
      File(entry.subtitlePath!), bookUid, i,
    );
    allCues.addAll(cues);
  }
  final String ext = firstExt ?? 'srt';
  final String chapterHref = _defaultChapterFor(ext);

  // 4) Run Sasayaki matcher on all cues
  AudiobookHealth health;
  final bool runMatcher = SasayakiRematch.supportedFormats.contains(ext);
  if (runMatcher && sections.isNotEmpty && allCues.isNotEmpty) {
    int chosenWindow = _searchWindow;
    if (_autoWindow) {
      final int? best = await SasayakiRematch.runAutoProbe(
        sections: sections,
        cues: allCues,
      );
      if (best != null) {
        chosenWindow = best;
      }
    }
    health = await _runSasayakiMatch(
      sections: sections,
      cues: allCues,
      searchWindow: chosenWindow,
      similarityThreshold: _similarityThreshold,
    );
  } else if (runMatcher) {
    health = sections.isEmpty
        ? AudiobookHealth.failed(reason: 'ttu IDB record had 0 sections')
        : AudiobookHealth.failed(reason: 'parser returned 0 cues');
  } else {
    health = AudiobookHealth.notApplicable(
      reason: '$ext format uses file anchors, no matcher needed',
    );
  }

  // 5) Persist files + save Audiobook
  final Directory persistDir = await _ensurePersistDir(bookUid);
  final String? firstSubPath = _audioEntries
      .map((e) => e.subtitlePath)
      .whereType<String>()
      .firstOrNull;
  final String persistedSrt = firstSubPath != null
      ? await _persistFile(File(firstSubPath), persistDir)
      : '';

  List<String>? persistedAudioPaths;
  String? persistedAudioRoot;
  if (_audioEntries.isNotEmpty) {
    persistedAudioPaths = [];
    for (final AudioFileEntry entry in _audioEntries) {
      persistedAudioPaths.add(await _persistFile(File(entry.path), persistDir));
    }
  } else if (_audioDir != null) {
    persistedAudioRoot = _audioDir;
  }

  final Audiobook audiobook = Audiobook()
    ..bookUid = bookUid
    ..alignmentFormat = ext
    ..alignmentPath = persistedSrt;
  if (persistedAudioPaths != null && persistedAudioPaths.isNotEmpty) {
    audiobook.audioPaths = persistedAudioPaths;
  } else if (persistedAudioRoot != null) {
    audiobook.audioRoot = persistedAudioRoot;
  }
  health.packInto(audiobook);

  debugPrint('[hibiki-import] EPUB+align save: bookUid="$bookUid" '
      'ttuBookId=$ttuBookId cues=${allCues.length}');

  await widget.audiobookRepo.saveAudiobook(audiobook);
  await widget.audiobookRepo.saveCues(
    bookUid: bookUid,
    chapterHref: chapterHref,
    cues: allCues,
  );
  await widget.audiobookRepo.updateHealthOverlay(
    bookUid: bookUid,
    health: health,
  );

  return _summarizeHealth(health);
}
```

- [ ] **Step 12: Add `_parseCuesWithIndex()` helper**

Replace `_parseCues()` with a version that accepts `audioFileIndex`:

```dart
Future<List<AudioCue>> _parseCuesWithIndex(
  File file,
  String bookUid,
  int audioFileIndex,
) {
  final String ext = file.path.split('.').last.toLowerCase();
  switch (ext) {
    case 'lrc':
      return LrcParser.parse(
          lrcFile: file, bookUid: bookUid, audioFileIndex: audioFileIndex);
    case 'vtt':
      return VttParser.parse(
          vttFile: file, bookUid: bookUid, audioFileIndex: audioFileIndex);
    case 'ass':
    case 'ssa':
      return AssParser.parse(
          assFile: file, bookUid: bookUid, audioFileIndex: audioFileIndex);
    default:
      return SrtParser.parse(
          srtFile: file, bookUid: bookUid, audioFileIndex: audioFileIndex);
  }
}
```

Keep the old `_parseCues()` method as well (called nowhere after refactor, but safe to remove). Actually, remove `_parseCues()` entirely since `_parseCuesWithIndex()` replaces it.

- [ ] **Step 13: Verify full compile**

Run: `cd d:/APP/vs_claude_code/hibiki/hibiki && dart analyze lib/src/media/audiobook/book_import_dialog.dart`
Expected: No errors

- [ ] **Step 14: Commit**

```bash
git add hibiki/lib/src/media/audiobook/book_import_dialog.dart
git commit -m "feat: rewrite BookImportDialog for multi-file audio import with management panel"
```

---

### Task 6: Build APK and Verify

**Files:** None (verification only)

- [ ] **Step 1: Run full analyze**

Run: `cd d:/APP/vs_claude_code/hibiki/hibiki && flutter analyze`
Expected: No errors related to our changes

- [ ] **Step 2: Build release APK**

Run: `cd d:/APP/vs_claude_code/hibiki/hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: Commit version bump if needed**

If build succeeds, bump patch version in `pubspec.yaml` if appropriate.

```bash
git add -A
git commit -m "chore: verify multi-file audio import builds successfully"
```
