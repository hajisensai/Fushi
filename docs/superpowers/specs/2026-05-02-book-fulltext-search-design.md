# Book Full-Text Search Design

## Overview

Add in-book full-text search to the EPUB reader. Users enter a keyword in the settings sheet, see all matches across all chapters with context preview, and tap to jump to any match.

## Architecture

### ttu fork: `__ttuSearchBook(query)` JS API

Registered in `+page.svelte` onMount, cleaned up in onDestroy.

**Input:** `query: string` (search keyword)

**Algorithm:**
1. Read `sectionList$` for section metadata (reference IDs, labels, startCharacter)
2. Get the live DOM's full book HTML container (`document.getElementById(ref)`) for each section
3. Extract `textContent` from each section's DOM element
4. Find all substring matches (case-insensitive for Latin, exact for CJK)
5. For each match, compute `charOffset` within that section's text (aligned with `__ttuScrollToCharOffset` semantics)
6. Extract context: 20 chars before + match + 20 chars after

**Output:** `JSON.stringify(Array<{sectionIndex: number, charOffset: number, context: string, matchStart: number}>)`

- `matchStart`: index within `context` where the match begins (for highlight rendering)

**Edge cases:**
- Empty query → return `[]`
- No matches → return `[]`
- Section DOM element not found (not yet rendered) → fall back to parsing `rawBookData$.elementHtml` via DOMParser for that section

**Note on charOffset:** ttu only renders one section's DOM at a time. For non-current sections, `textContent` must come from parsing `elementHtml`. The `charOffset` must count only text nodes (excluding HTML tags, ruby annotation text in `<rt>` elements) to align with `__ttuScrollToCharOffset`'s bookmark-based scrolling which uses `exploredCharCount`.

### hibiki Flutter: Search UI in Settings Sheet

**Location:** `AudiobookSettingsSheet` in `audiobook_play_bar.dart`, inserted after `_buildProgressSection`.

**Components:**
- `_buildSearchSection(theme)`: TextField + IconButton(Icons.search)
- On submit: call `AudiobookBridge.searchBook(controller, query)` 
- Results displayed in a `ConstrainedBox(maxHeight: 320)` + `ListView.builder`
- Each result tile: chapter label (from TOC) + context with match highlighted via `TextSpan`
- Header: "N results found" 
- Tap result → `Navigator.pop(context)` → callback `onSearchJump(sectionIndex, charOffset)`

**State:** Local to `_AudiobookSettingsSheetState`:
- `List<BookSearchResult> _searchResults`
- `bool _isSearching`
- `String _lastSearchQuery`

### hibiki: AudiobookBridge.searchBook

New static method in `audiobook_bridge.dart`:

```dart
static Future<List<BookSearchResult>> searchBook(
  InAppWebViewController controller,
  String query,
) async { ... }
```

Calls `evaluateJavascript` with `__ttuSearchBook(escapedQuery)`, parses JSON result.

**BookSearchResult model** (defined in same file, no Isar):
```dart
class BookSearchResult {
  final int sectionIndex;
  final int charOffset;
  final String context;
  final int matchStart;
}
```

### Jump flow

Settings sheet passes a new callback `onSearchJump` to the reader page. Reader page implements it using the existing pattern:

```dart
onSearchJump: (int sectionIndex, int charOffset) async {
  await AudiobookBridge.requestSectionNav(_controller, sectionIndex: sectionIndex);
  await Future.delayed(const Duration(milliseconds: 500));
  await _controller.evaluateJavascript(
    source: 'window.__ttuScrollToCharOffset($sectionIndex, $charOffset)',
  );
}
```

### i18n strings

| Key | EN | Usage |
|-----|-----|-------|
| `book_search` | `Search in Book` | Section title |
| `book_search_hint` | `Enter keyword...` | TextField hint |
| `book_search_results` | `{n} results found` | Results header |
| `book_search_no_results` | `No results found` | Empty state |
| `book_searching` | `Searching...` | Loading state |

## Files Changed

| File | Change |
|------|--------|
| `d:/ttu-fork/apps/web/src/routes/b/+page.svelte` | Register `__ttuSearchBook`, cleanup on destroy |
| `hibiki/lib/src/media/audiobook/audiobook_bridge.dart` | Add `searchBook()` static method + `BookSearchResult` class |
| `hibiki/lib/src/media/audiobook/audiobook_play_bar.dart` | Add search section to `AudiobookSettingsSheet`, add `onSearchJump` callback |
| `hibiki/lib/src/pages/implementations/reader_ttu_source_page.dart` | Wire `onSearchJump` callback in `_showReaderSettingsSheet` |
| `hibiki/lib/i18n/strings.g.dart` | Add search-related i18n keys |

## Not in scope

- Search history / recent searches
- Regex or fuzzy matching
- Highlighting matches in the WebView after jump
- Search across multiple books
