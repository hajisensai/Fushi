# Book Full-Text Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add full-book text search to the EPUB reader — user types a keyword in the settings sheet, sees all matches across all chapters with context, taps to jump.

**Architecture:** ttu fork exposes a new `__ttuSearchBook(query)` JS API that parses `elementHtml` from `rawBookData$`, searches all sections' text (excluding `<rt>` ruby), and returns matches with `charOffset` aligned to `__ttuScrollToCharOffset`'s Japanese-character-count semantics. Flutter side adds a search section to `AudiobookSettingsSheet`, calls the API via `AudiobookBridge.searchBook()`, and jumps via existing `__ttuScrollToCharOffset`.

**Tech Stack:** TypeScript (ttu fork Svelte), Dart/Flutter (hibiki), InAppWebView JS bridge

**Key constraint — charOffset alignment:** ttu counts characters using `getCharacterCount()` which applies a Japanese-only regex (`isNotJapaneseRegex`) and excludes `<rt>` text nodes. The search API must compute `charOffset` using the exact same logic so `__ttuScrollToCharOffset` scrolls to the right position.

---

### Task 1: ttu fork — Register `__ttuSearchBook` JS API

**Files:**
- Modify: `d:/ttu-fork/apps/web/src/routes/b/+page.svelte` (around line 602–1011, the `onMount` block)

- [ ] **Step 1: Add `__ttuSearchBook` to the window type declaration**

In `+page.svelte`, inside the `onMount` callback, find the type declaration block starting at line 603. Add the new API to the type:

```typescript
// Add after line 628 (__ttuClearCueSpans)
__ttuSearchBook?: (query: string) => string;
```

- [ ] **Step 2: Implement `__ttuSearchBook`**

After the `__ttuClearCueSpans` implementation (around line 828, after the `w.__ttuWrapCueSpans` block ends), add:

```typescript
w.__ttuSearchBook = (query: string): string => {
  if (!query || !query.trim()) return '[]';
  const q = query.trim().toLowerCase();
  const data = rawBookData$.getValue();
  if (!data?.elementHtml) return '[]';

  const sections = sectionList$.getValue();
  if (!sections.length) return '[]';

  // Parse the full book HTML once
  const parser = new DOMParser();
  const doc = parser.parseFromString(
    `<div>${data.elementHtml}</div>`,
    'text/html'
  );

  const isNotJapaneseRegex =
    /[^0-9A-Z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚｦ-ﾝ⺀-⿕㐀-䶿一-鿿豈-﫿\u{20000}-\u{2A6DF}\u{2A700}-\u{2B73F}\u{2B740}-\u{2B81F}\u{2B820}-\u{2CEAF}\u{2CEB0}-\u{2EBEF}\u{30000}-\u{3134F}]+/gimu;

  function getTextNodesSkipRt(node: Node): string {
    if (node.nodeName === 'RT') return '';
    if (node instanceof HTMLElement) {
      if (node.hasAttribute('aria-hidden') || node.hasAttribute('hidden')) return '';
    }
    if (node.nodeType === Node.TEXT_NODE) return node.textContent || '';
    let result = '';
    for (const child of Array.from(node.childNodes)) {
      result += getTextNodesSkipRt(child);
    }
    return result;
  }

  // Count Japanese characters in a string (mirrors get-character-count.ts)
  function countJpChars(s: string): number {
    return Array.from(s.replace(isNotJapaneseRegex, '')).length;
  }

  type SearchHit = {
    sectionIndex: number;
    charOffset: number;
    context: string;
    matchStart: number;
  };
  const results: SearchHit[] = [];
  const maxResults = 200;

  for (let si = 0; si < sections.length && results.length < maxResults; si++) {
    const ref = sections[si].reference;
    const sectionEl = doc.querySelector(`#${CSS.escape(ref)}`);
    if (!sectionEl) continue;

    const text = getTextNodesSkipRt(sectionEl);
    const textLower = text.toLowerCase();

    let searchPos = 0;
    while (searchPos < textLower.length && results.length < maxResults) {
      const idx = textLower.indexOf(q, searchPos);
      if (idx === -1) break;

      // charOffset = Japanese char count of text[0..idx)
      const charOffset = countJpChars(text.slice(0, idx));

      // Context: 20 chars before + match + 20 chars after
      const ctxStart = Math.max(0, idx - 20);
      const ctxEnd = Math.min(text.length, idx + query.length + 20);
      const context = text.slice(ctxStart, ctxEnd);
      const matchStart = idx - ctxStart;

      results.push({ sectionIndex: si, charOffset, context, matchStart });
      searchPos = idx + Math.max(1, query.length);
    }
  }

  return JSON.stringify(results);
};
```

- [ ] **Step 3: Add cleanup in the onDestroy return block**

Find the cleanup block (around line 994–1011) where `delete w.__ttuGoToSection` etc. are listed. Add:

```typescript
delete w.__ttuSearchBook;
```

- [ ] **Step 4: Add `rawBookData$` to the `getValue()` availability**

The `rawBookData$` observable uses `share()` (line 339), not `shareReplay()`. This means `getValue()` is not available. We need to capture the latest value. Find line 339:

```typescript
share()
```

Change to:

```typescript
shareReplay({ refCount: true, bufferSize: 1 })
```

This matches `bookId$` (line 243) which already uses `shareReplay`. Since `rawBookData$` is always subscribed (by `bookData$`, `leaveIfBookMissing$`, `initBookmarkData$`), `refCount: true` is safe.

- [ ] **Step 5: Build ttu fork**

```bash
cd /d/ttu-fork && pnpm build
```

- [ ] **Step 6: Copy build output to hibiki assets**

```bash
# Preserve the hand-maintained fonts/ subdirectory
cp -r /d/ttu-fork/apps/web/build/* /d/APP/vs_claude_code/hibiki/hibiki/assets/ttu-ebook-reader/ 
```

(The `fonts/` directory in the destination is not overwritten because the build output doesn't contain a `fonts/` directory.)

- [ ] **Step 7: Commit ttu fork changes**

```bash
cd /d/ttu-fork && git add -A && git commit -m "feat(reader): [hibiki] add __ttuSearchBook full-text search API

Parses elementHtml from rawBookData$, searches all sections' text
(excluding <rt> ruby), returns matches with charOffset aligned to
__ttuScrollToCharOffset's Japanese-character-count semantics.
Limited to 200 results. rawBookData$ changed from share() to
shareReplay() to support getValue() in the search function."
```

---

### Task 2: hibiki — Add `BookSearchResult` model and `AudiobookBridge.searchBook()`

**Files:**
- Modify: `d:/APP/vs_claude_code/hibiki/hibiki/lib/src/media/audiobook/audiobook_bridge.dart` (add after `TtuReaderSettings` class, around end of file)

- [ ] **Step 1: Add `BookSearchResult` class**

At the end of `audiobook_bridge.dart` (after the `TtuReaderSettings` class), add:

```dart
/// A single match from `__ttuSearchBook`. [charOffset] uses ttu's
/// Japanese-character-count semantics, passable directly to
/// [__ttuScrollToCharOffset].
class BookSearchResult {
  const BookSearchResult({
    required this.sectionIndex,
    required this.charOffset,
    required this.context,
    required this.matchStart,
  });

  final int sectionIndex;
  final int charOffset;
  final String context;
  final int matchStart;

  factory BookSearchResult.fromMap(Map<String, dynamic> m) {
    return BookSearchResult(
      sectionIndex: (m['sectionIndex'] as num).toInt(),
      charOffset: (m['charOffset'] as num).toInt(),
      context: m['context'] as String? ?? '',
      matchStart: (m['matchStart'] as num?)?.toInt() ?? 0,
    );
  }
}
```

- [ ] **Step 2: Add `searchBook` static method to `AudiobookBridge`**

Inside the `AudiobookBridge` class, add a new static method (after the existing `setReaderSetting` method):

```dart
/// Full-text search across all book sections via ttu's `__ttuSearchBook`.
static Future<List<BookSearchResult>> searchBook(
  InAppWebViewController controller,
  String query,
) async {
  if (query.trim().isEmpty) return const [];
  final String escaped = jsonEncode(query);
  final Object? raw = await controller.evaluateJavascript(
    source: '(function(){try{return window.__ttuSearchBook($escaped);}catch(e){return "[]";}})()',
  );
  if (raw == null) return const [];
  final String jsonStr = raw.toString();
  if (jsonStr.isEmpty || jsonStr == 'null') return const [];
  final List<dynamic> list = jsonDecode(jsonStr) as List<dynamic>;
  return list
      .map((e) => BookSearchResult.fromMap(e as Map<String, dynamic>))
      .toList();
}
```

- [ ] **Step 3: Verify with `dart analyze`**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki && dart analyze lib/src/media/audiobook/audiobook_bridge.dart
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
cd /d/APP/vs_claude_code/hibiki && git add hibiki/lib/src/media/audiobook/audiobook_bridge.dart && git commit -m "feat: add BookSearchResult model and AudiobookBridge.searchBook()

Calls ttu fork's __ttuSearchBook JS API, parses JSON results.
charOffset aligned to __ttuScrollToCharOffset semantics."
```

---

### Task 3: hibiki — Add i18n strings

**Files:**
- Modify: `d:/APP/vs_claude_code/hibiki/hibiki/lib/i18n/strings.g.dart`

- [ ] **Step 1: Add English strings**

Find the block of reader-related strings (around line 693–730). Add after `reader_settings_section`:

```dart
String get book_search => 'Search in Book';
String get book_search_hint => 'Enter keyword...';
String book_search_results({required Object n}) => '${n} results found';
String get book_search_no_results => 'No results found';
String get book_searching => 'Searching...';
```

- [ ] **Step 2: Add Japanese fallback strings**

Find the Japanese override class (search for `@override String get search => '???';` around line 910). Add the corresponding overrides near the other reader strings:

```dart
@override String get book_search => '本の中を検索';
@override String get book_search_hint => 'キーワードを入力...';
@override String book_search_results({required Object n}) => '${n} 件の結果';
@override String get book_search_no_results => '結果が見つかりません';
@override String get book_searching => '検索中...';
```

- [ ] **Step 3: Verify with `dart analyze`**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki && dart analyze lib/i18n/strings.g.dart
```

- [ ] **Step 4: Commit**

```bash
cd /d/APP/vs_claude_code/hibiki && git add hibiki/lib/i18n/strings.g.dart && git commit -m "feat: add i18n strings for book search"
```

---

### Task 4: hibiki — Add search section to `AudiobookSettingsSheet`

**Files:**
- Modify: `d:/APP/vs_claude_code/hibiki/hibiki/lib/src/media/audiobook/audiobook_play_bar.dart` (class `AudiobookSettingsSheet` starting at line 132)

- [ ] **Step 1: Add `onSearchJump` callback to `AudiobookSettingsSheet`**

In the `AudiobookSettingsSheet` widget fields (around line 133–157), add a new field:

```dart
final Future<void> Function(int sectionIndex, int charOffset)? onSearchJump;
```

Add the corresponding constructor parameter (after `onFloatingLyricFontSizeChanged`):

```dart
this.onSearchJump,
```

- [ ] **Step 2: Add search state to `_AudiobookSettingsSheetState`**

In `_AudiobookSettingsSheetState` (around line 186), add fields after `_cueJumpController`:

```dart
final TextEditingController _searchController = TextEditingController();
List<BookSearchResult> _searchResults = const [];
bool _isSearching = false;
```

Update `dispose` to also dispose `_searchController`:

```dart
@override
void dispose() {
  _cueJumpController.dispose();
  _searchController.dispose();
  super.dispose();
}
```

- [ ] **Step 3: Add `_buildSearchSection` method**

After the `_buildProgressSection` method (around line 362), add:

```dart
Widget _buildSearchSection(ThemeData theme) {
  return StatefulBuilder(
    builder: (BuildContext ctx, StateSetter setLocal) {
      Future<void> doSearch() async {
        final String query = _searchController.text.trim();
        if (query.isEmpty) return;
        setLocal(() => _isSearching = true);
        try {
          final List<BookSearchResult> results =
              await AudiobookBridge.searchBook(
            widget.webViewController,
            query,
          );
          setLocal(() {
            _searchResults = results;
            _isSearching = false;
          });
        } catch (e) {
          debugPrint('[hibiki-search] error: $e');
          setLocal(() {
            _searchResults = const [];
            _isSearching = false;
          });
        }
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.book_search, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: t.book_search_hint,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: const OutlineInputBorder(),
                  ),
                  style: theme.textTheme.bodyMedium,
                  onSubmitted: (_) => doSearch(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 40,
                child: FilledButton.tonal(
                  onPressed: _isSearching ? null : doSearch,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    visualDensity: VisualDensity.compact,
                  ),
                  child: _isSearching
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search, size: 20),
                ),
              ),
            ],
          ),
          if (_searchResults.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              t.book_search_results(n: _searchResults.length),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _searchResults.length,
                itemBuilder: (_, int i) {
                  final BookSearchResult r = _searchResults[i];
                  final String query = _searchController.text.trim();
                  final int tocIdx = r.sectionIndex;
                  final List<TtuTocEntry> toc = widget.toc;
                  final String chapterLabel = tocIdx < toc.length
                      ? toc[tocIdx].label
                      : t.go_to_chapter(n: tocIdx + 1);

                  // Build highlighted context
                  final String before =
                      r.context.substring(0, r.matchStart);
                  final String match = r.context.substring(
                    r.matchStart,
                    (r.matchStart + query.length)
                        .clamp(0, r.context.length),
                  );
                  final String after = r.context.substring(
                    (r.matchStart + query.length)
                        .clamp(0, r.context.length),
                  );

                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      chapterLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    subtitle: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: before),
                          TextSpan(
                            text: match,
                            style: TextStyle(
                              backgroundColor: theme
                                  .colorScheme.primaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          TextSpan(text: after),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      widget.onSearchJump?.call(
                        r.sectionIndex,
                        r.charOffset,
                      );
                    },
                  );
                },
              ),
            ),
          ] else if (!_isSearching &&
              _searchController.text.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              t.book_search_no_results,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      );
    },
  );
}
```

- [ ] **Step 4: Insert search section into the `build` method**

In the `build` method of `_AudiobookSettingsSheetState` (around line 265), find the children list. Insert the search section after `_buildProgressSection(theme)`:

Find:
```dart
_buildProgressSection(theme),
if (widget.controller != null &&
```

Replace with:
```dart
_buildProgressSection(theme),
const SizedBox(height: 16),
_buildSearchSection(theme),
if (widget.controller != null &&
```

- [ ] **Step 5: Add import for `BookSearchResult`**

The `BookSearchResult` class is in `audiobook_bridge.dart` which should already be imported in `audiobook_play_bar.dart`. Verify by checking the existing imports at the top of the file. If not present, add:

```dart
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
```

- [ ] **Step 6: Verify with `dart analyze`**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki && dart analyze lib/src/media/audiobook/audiobook_play_bar.dart
```

- [ ] **Step 7: Commit**

```bash
cd /d/APP/vs_claude_code/hibiki && git add hibiki/lib/src/media/audiobook/audiobook_play_bar.dart && git commit -m "feat: add search section to AudiobookSettingsSheet

TextField + search button, results with highlighted context,
tap to jump via onSearchJump callback."
```

---

### Task 5: hibiki — Wire `onSearchJump` in reader page

**Files:**
- Modify: `d:/APP/vs_claude_code/hibiki/hibiki/lib/src/pages/implementations/reader_ttu_source_page.dart` (inside `_showReaderSettingsSheet`, around line 2728)

- [ ] **Step 1: Add `onSearchJump` callback to `AudiobookSettingsSheet` constructor call**

In `_showReaderSettingsSheet` (starting at line 2680), find the `AudiobookSettingsSheet(` constructor call (around line 2728). Add the `onSearchJump` parameter after `onExitReader`:

```dart
onSearchJump: (int sectionIndex, int charOffset) async {
  if (_dropStaleSectionNavigation(sectionIndex, 'search-jump')) {
    return;
  }
  await AudiobookBridge.requestSectionNav(
    _controller,
    sectionIndex: sectionIndex,
  );
  await Future.delayed(const Duration(milliseconds: 500));
  try {
    await _controller.evaluateJavascript(
      source: 'window.__ttuScrollToCharOffset($sectionIndex, $charOffset)',
    );
  } catch (e) {
    debugPrint('[hibiki-search] jump error: $e');
  }
},
```

- [ ] **Step 2: Verify with `dart analyze`**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki && dart analyze lib/src/pages/implementations/reader_ttu_source_page.dart
```

- [ ] **Step 3: Commit**

```bash
cd /d/APP/vs_claude_code/hibiki && git add hibiki/lib/src/pages/implementations/reader_ttu_source_page.dart && git commit -m "feat: wire onSearchJump in reader settings sheet

Uses requestSectionNav + __ttuScrollToCharOffset to jump
to search results, same pattern as bookmark jump."
```

---

### Task 6: Build APK and verify

**Files:** None (build + test only)

- [ ] **Step 1: Build release APK**

```bash
cd /d/APP/vs_claude_code/hibiki/hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64
```

- [ ] **Step 2: Commit ttu assets if not yet committed**

```bash
cd /d/APP/vs_claude_code/hibiki && git add hibiki/assets/ttu-ebook-reader/ && git commit -m "chore: update ttu-ebook-reader build with __ttuSearchBook API"
```

- [ ] **Step 3: Test on emulator**

1. Install APK on emulator
2. Open any EPUB with multiple chapters
3. Open settings sheet (⚙ button)
4. Find "Search in Book" section
5. Type a keyword that appears in the book
6. Verify results show with chapter names and highlighted context
7. Tap a result → sheet closes → reader jumps to the correct position
8. Search for a keyword that spans multiple chapters → verify results from different chapters
9. Search for non-existent text → verify "No results found" message
