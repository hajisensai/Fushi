# Multi-File Audio Import with Sorting & Chapter Mapping

## Problem

When importing audiobooks with per-chapter audio files (e.g., `ch1.mp3`, `ch2.mp3`), users need:

1. **Natural sorting** — `track1, track2, track10` instead of `track1, track10, track2`
2. **Manual drag reorder** — alphabetical order isn't always correct
3. **Chapter mapping** — assign each audio file to an EPUB chapter
4. **Per-file subtitles** — each audio file has its own subtitle (SRT/LRC/VTT/ASS), mixed formats allowed
5. **Multi-file per chapter** — one chapter can have multiple audio+subtitle pairs

## Data Structure

### New: `AudioFileEntry`

```dart
class AudioFileEntry {
  final String path;
  String label;           // default = filename without extension
  int? mappedSection;     // EpubSection.index, null = auto-assign by order
  String? subtitlePath;   // paired subtitle file, null = unpaired
}
```

This replaces the raw `List<String>? _audioPaths` + single `String? _srtPath` in `BookImportDialog`.

### Unchanged

- `AudioCue` table: `audioFileIndex` = position in final sorted `AudioFileEntry` list
- `Audiobook` model: `audioPaths` remains `List<String>` (extracted from entries)
- `SrtBook` model: same
- `AudiobookPlayerController`: reads `audioFileIndex` + cue timeline, no changes needed

## Import Flow

### Current Flow
1. Pick EPUB (optional)
2. Pick single subtitle file
3. Pick audio (folder or files)
4. Import

### New Flow
1. Pick EPUB (optional)
2. Pick multiple audio files → natural-sorted into `List<AudioFileEntry>`
3. Pick multiple subtitle files → auto-pair by filename similarity
4. **Management panel** appears:
   - Drag handles for reordering
   - Chapter dropdown per file (from EPUB spine; hidden if no EPUB)
   - Subtitle pairing column (auto-matched shown, unmatched show warning, tap to reassign)
   - "Add audio" / "Add subtitle" buttons for incremental additions
5. Import → per-file subtitle parsing → per-file matcher run → merge cues → save

### Folder Mode
When user picks a folder instead of individual files:
- Scan folder for audio files
- Generate `AudioFileEntry` list with natural sort
- Enter same management panel

## Management Panel UI

```
┌─ Audio File Management ──────────────────────┐
│ ≡  ch1_part1.mp3    [Chapter 1 ▼]  intro.srt │
│ ≡  ch1_part2.mp3    [Chapter 1 ▼]  ch1p2.lrc │
│ ≡  ch2.mp3          [Chapter 2 ▼]  ch2.srt   │
│ ≡  bonus.mp3        [Auto     ▼]  ⚠ Unpaired │
│                                               │
│         [+ Add Audio]  [+ Add Subtitle]       │
└───────────────────────────────────────────────┘
```

- `≡` = drag handle (ReorderableListView)
- Chapter dropdown: populated from `TtuIdbReader.readBookRecord()` sections
- Subtitle column: tap to manually pick/reassign; shows filename if paired, warning icon if not
- Each row is compact (single line, ~48dp height)

## Auto-Pairing Algorithm

When subtitle files are selected:

1. For each subtitle file, extract filename stem (strip extension, normalize: lowercase, strip whitespace/punctuation)
2. For each unpaired audio entry, extract filename stem (same normalization)
3. Match by longest common substring or exact stem equality
4. Remaining unmatched subtitles: show in a pool for manual assignment

Priority: exact stem match > contains match > unmatched.

## Matcher Changes

### Current
`EpubSrtMatcher` receives one cue list from a single subtitle file. All cues have `audioFileIndex = 0`.

### New
- Each `AudioFileEntry` with a `subtitlePath` is parsed independently by the appropriate parser (SRT/LRC/VTT/ASS, determined by extension)
- Each file's cues get `audioFileIndex` = file's position in the sorted list
- If `mappedSection != null`, the matcher constrains search to that section's text range
- All cue lists are concatenated and saved to the database in one batch

### Isolate Strategy
Current matcher already runs in an isolate. The new per-file parsing can run sequentially within the same isolate (each file is small). No architecture change needed.

## Backward Compatibility

- **Single file scenario** (1 audio + 1 subtitle): management panel shows one row. UX nearly identical to current.
- **Legacy imports**: existing `Audiobook` records with `audioPaths` and `audioPathsJson` work unchanged. The management panel is only for new imports.
- **Database schema**: no migration needed. `audioPathsJson` already stores ordered paths. Subtitle paths are consumed at import time (parsed into cues), not persisted separately.

## What Changes

| Component | Change |
|-----------|--------|
| `BookImportDialog` | Replace `_srtPath` + `_audioPaths` with `List<AudioFileEntry>`; add management panel widget; add subtitle multi-picker; add auto-pairing logic |
| `BookImportDialog._doImport()` | Loop over entries, parse each subtitle, assign `audioFileIndex`, merge cues |
| Natural sort utility | New `naturalCompare(String a, String b)` function |
| `AudioFileEntry` model | New file in `lib/src/media/audiobook/` |

## What Doesn't Change

| Component | Why |
|-----------|-----|
| `AudioCue` table | `audioFileIndex` semantic unchanged |
| `Audiobook` / `SrtBook` models | `audioPaths` is still `List<String>` |
| `AudiobookPlayerController` | Reads cues + file list, order-agnostic |
| `AudiobookImportDialog` | Attach-to-existing flow unchanged |
| All parsers | Already return cues with configurable `audioFileIndex` |
| Health tracking | Per-book, not per-file |
| `EpubSrtMatcher` | Called per-file now, but API unchanged |

## Edge Cases

1. **No EPUB selected**: chapter dropdown hidden, `mappedSection` stays null, all cues go into a single SrtBook
2. **Subtitle without matching audio**: shown in unmatched pool, user must assign or discard
3. **Audio without subtitle**: allowed (file contributes silence/ambient to the chapter sequence, no cues generated)
4. **Duplicate chapter assignment**: multiple files map to same section — valid, cues merged in list order
5. **Empty subtitle file**: parsed to 0 cues, no error, file still occupies its `audioFileIndex` slot for playback
