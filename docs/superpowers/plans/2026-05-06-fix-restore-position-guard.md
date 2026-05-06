# Fix Position Restore: `__hoshiRestoreInFlight` Guard + `viewportStable` rAF Detection

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opening a book never shows the wrong position — mask stays until saved offset is reached and stable.

**Architecture:** Three-layer fix: (1) ttu fork adds `__hoshiRestoreInFlight` JS flag that suppresses ttu's own `scrollTo(0)` resets during programmatic restore; (2) JS `__hibikiScrollToNormOffset` replaces single-frame `signalDone` with rAF stability polling that checks 3 consecutive frames of no offset drift before calling `viewportStable`; (3) Dart `_finishRestore` waits for `viewportStable` handler instead of timer-based verify, then removes mask. Existing `_scheduleRestoreVerify` / `_extendAutoScrollGuard` / `_restoreVerifyTimer` are deleted.

**Tech Stack:** SvelteKit (ttu fork) / RxJS / Flutter InAppWebView / Dart

---

## Root Cause Diagram

```
BEFORE (broken):
  __ttuGoToSection(13) → nextChapter$.next()
    → sectionIndex$.next(13) + concretePageManager.scrollTo(0) ← RESETS SCROLL
    → currentSection$ fires → scrollEl.scrollTo(0,0)           ← RESETS SCROLL
    → sectionRenderCompleteGlobal$ fires
    → deferred sectionChanged emits
    → Dart _finishRestore → scrollToNormOffset → page 13 ← CORRECT
    → onTitleChanged → _injectAudiobookBridge → __hoshiAutoScrollInFlight=false ← CLEARS GUARD
    → ttu bookmarkData.then → scroll side-effects ← MAY RESET AGAIN
    → 800ms guard expires → pos-save fires with wrong offset

AFTER (fixed):
  __ttuGoToSection(13) → nextChapter$.next()
    → checks __hoshiRestoreInFlight → SKIP scrollTo(0)
    → currentSection$ fires → checks __hoshiRestoreInFlight → SKIP scrollTo(0,0)
    → sectionRenderCompleteGlobal$ fires
    → deferred sectionChanged emits
    → Dart _finishRestore → scrollToNormOffset → page 13
    → JS rAF polling: 3 frames stable → callHandler('viewportStable')
    → Dart receives viewportStable → clear __hoshiRestoreInFlight → remove mask
```

---

### Task 1: ttu fork — add `__hoshiRestoreInFlight` guard to scroll resets

**Files:**
- Modify: `d:\ttu-fork\apps\web\src\lib\components\book-reader\book-reader-paginated\book-reader-paginated.svelte:591-592` and `:856-858`
- Modify: `d:\ttu-fork\apps\web\src\lib\components\book-reader\book-reader-continuous\book-reader-continuous.svelte:463`

- [ ] **Step 1: Guard the `currentSection$` scroll reset in paginated mode**

In `book-reader-paginated.svelte`, line 591-593, change:

```typescript
    if (scrollEl) {
      scrollEl.scrollTo({ left: 0, top: 0 });
    }
```

To:

```typescript
    if (scrollEl && !(window as any).__hoshiRestoreInFlight) {
      scrollEl.scrollTo({ left: 0, top: 0 });
    }
```

- [ ] **Step 2: Guard the `nextChapter$` scroll reset in paginated mode**

In `book-reader-paginated.svelte`, line 856-858, change:

```typescript
    if (nextSectionIndex > -1) {
      sectionIndex$.next(nextSectionIndex);
      concretePageManager?.scrollTo(0, true);
    }
```

To:

```typescript
    if (nextSectionIndex > -1) {
      sectionIndex$.next(nextSectionIndex);
      if (!(window as any).__hoshiRestoreInFlight) {
        concretePageManager?.scrollTo(0, true);
      }
    }
```

- [ ] **Step 3: Guard `scrollToBookmark` in continuous mode (belt-and-suspenders)**

In `book-reader-continuous.svelte`, the `bookmarkData.then` block around line 463 already checks `__hoshiManagesPosition`. Add a second guard for the resize-scroll path. Find the `isResizeScroll` assignment around line 399-402:

```typescript
      isResizeScroll = true;
      pageManagerConcrete.scrollTo(scrollPos);
```

Change to:

```typescript
      if (!(window as any).__hoshiRestoreInFlight) {
        isResizeScroll = true;
        pageManagerConcrete.scrollTo(scrollPos);
      }
```

- [ ] **Step 4: Build ttu fork**

```bash
cd /d/ttu-fork && pnpm build
```

- [ ] **Step 5: Copy build to hibiki assets**

```bash
rsync -a --delete --exclude='fonts/' /d/ttu-fork/apps/web/build/ /d/APP/vs_claude_code/hibiki/hibiki/assets/ttu-ebook-reader/
```

- [ ] **Step 6: Commit ttu fork**

```bash
cd /d/ttu-fork && git add -A && git commit -m "fix(reader): [hibiki] guard scroll resets with __hoshiRestoreInFlight during position restore"
```

---

### Task 2: JS bridge — replace `signalDone` with `viewportStable` rAF polling

**Files:**
- Modify: `d:\APP\vs_claude_code\hibiki\hibiki\lib\src\media\audiobook\audiobook_bridge.dart:817-912` (`__hibikiScrollToNormOffset` function in `_readerPosFn`)
- Modify: `d:\APP\vs_claude_code\hibiki\hibiki\lib\src\media\audiobook\audiobook_bridge.dart:44-45` (guard init in `_highlightFn`)

- [ ] **Step 1: Replace `signalDone(true)` with `waitViewportStable` rAF polling**

In `audiobook_bridge.dart`, replace the entire `__hibikiScrollToNormOffset` function (lines 814-913) with:

```javascript
window.__hibikiScrollToNormOffset = function(section, offset, _retryCount) {
  var retry = _retryCount || 0;
  var maxRetries = 15;
  function signalDone(ok) {
    try {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('scrollToNormOffsetDone', {success: !!ok});
      }
    } catch(e2) {}
  }
  function signalStable(sec, off) {
    try {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('viewportStable', {section: sec, offset: off});
      }
    } catch(e2) {}
  }
  function waitStable(targetSection, targetOffset, retriesLeft) {
    var stableCount = 0;
    var prevOffset = -1;
    var maxFrames = 30;
    var frame = 0;
    function check() {
      frame++;
      if (frame > maxFrames) {
        signalStable(targetSection, targetOffset);
        return;
      }
      var cur = null;
      try {
        if (typeof window.__hibikiGetViewportNormOffset === 'function') {
          cur = window.__hibikiGetViewportNormOffset();
        }
      } catch(e) {}
      if (!cur) {
        requestAnimationFrame(check);
        return;
      }
      if (cur.section === targetSection && Math.abs(cur.offset - targetOffset) <= 5) {
        if (prevOffset === cur.offset) {
          stableCount++;
        } else {
          stableCount = 1;
          prevOffset = cur.offset;
        }
        if (stableCount >= 3) {
          signalStable(cur.section, cur.offset);
          return;
        }
        requestAnimationFrame(check);
        return;
      }
      stableCount = 0;
      prevOffset = -1;
      if (retriesLeft > 0) {
        console.log(JSON.stringify({
          'hibiki-message-type': 'viewportStable-drift',
          'target': targetOffset, 'actual': cur ? cur.offset : -1,
          'retriesLeft': retriesLeft
        }));
        window.__hibikiScrollToNormOffset(targetSection, targetOffset, 0);
        return;
      }
      signalStable(targetSection, targetOffset);
    }
    requestAnimationFrame(check);
  }
  try {
    var root = document.querySelector('.book-content-container') ||
               document.querySelector('.book-content');
    if (!root) {
      if (retry < maxRetries) {
        setTimeout(function() {
          window.__hibikiScrollToNormOffset(section, offset, retry + 1);
        }, 100);
        return;
      }
      signalDone(false);
      return;
    }
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        var p = n.parentNode;
        while (p && p !== root) {
          var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
          if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
          p = p.parentNode;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var normPos = 0;
    var node;
    while ((node = walker.nextNode())) {
      var txt = node.nodeValue || '';
      for (var k = 0; k < txt.length; ) {
        var ck = txt.codePointAt(k);
        var wk = (ck > 0xFFFF) ? 2 : 1;
        if (!window.__hoshiIsSkippable(ck)) {
          if (normPos + wk > offset) {
            var r = document.createRange();
            r.setStart(node, k);
            r.collapse(true);
            var rect = r.getBoundingClientRect();
            if (typeof window.__hoshiAlignToRect === 'function') {
              window.__hoshiAlignToRect(rect);
            } else {
              window.scrollBy(0, rect.top - 16);
            }
            requestAnimationFrame(function() {
              signalDone(true);
              waitStable(section, offset, 2);
            });
            return;
          }
          normPos += wk;
        }
        k += wk;
      }
    }
    if (normPos === 0 && retry < maxRetries) {
      setTimeout(function() {
        window.__hibikiScrollToNormOffset(section, offset, retry + 1);
      }, 100);
      return;
    }
    signalDone(false);
  } catch (e) {
    signalDone(false);
  }
};
```

**Key changes from the original:**
- `signalDone(true)` still fires after the first rAF (unchanged behavior — Dart `_scrollToNormOffsetCompleter` resolves immediately)
- NEW: `waitStable(section, offset, 2)` starts after `signalDone`, polls up to 30 rAFs (~500ms)
- Stability = same offset for 3 consecutive frames AND within ±5 of target
- If drift detected and retries remain, re-calls `__hibikiScrollToNormOffset` to re-scroll, then checks again
- After max frames or stable → calls `callHandler('viewportStable', {section, offset})`

- [ ] **Step 2: Ensure guard init stays conditional in `_highlightFn`**

Verify `audiobook_bridge.dart` line 44-45 already reads:

```javascript
if (window.__hoshiAutoScrollInFlight === undefined) window.__hoshiAutoScrollInFlight = false;
if (window.__hoshiAutoScrollTimer === undefined) window.__hoshiAutoScrollTimer = null;
```

(This was already changed in the current session. Confirm it's still conditional, not unconditional.)

- [ ] **Step 3: Add `__hoshiRestoreInFlight` guard to pos-save scroll listener**

In `reader_ttu_source_page.dart`, in the scroll listener JS string (line 2655), change:

```javascript
        if (window.__hoshiAutoScrollInFlight) {
          console.log(JSON.stringify({'hibiki-message-type':'pos-save-skip','reason':'autoScrollInFlight'}));
          return;
        }
```

To:

```javascript
        if (window.__hoshiAutoScrollInFlight || window.__hoshiRestoreInFlight) {
          console.log(JSON.stringify({'hibiki-message-type':'pos-save-skip','reason':'autoScrollInFlight'}));
          return;
        }
```

---

### Task 3: Dart — set/clear `__hoshiRestoreInFlight`, wait `viewportStable`, remove mask

**Files:**
- Modify: `d:\APP\vs_claude_code\hibiki\hibiki\lib\src\pages\implementations\reader_ttu_source_page.dart`
  - Fields area (~line 247): remove `_restoreVerifyTimer`, keep `_scrollToNormOffsetCompleter`
  - Handler registration (~line 1490): add `viewportStable` handler
  - `_maybeInjectAudiobookBridge` (~line 3091): keep restore-in-flight guard
  - `_bootstrapRestoreReaderPos` (~line 4003): set JS flag when starting restore
  - `_finishRestore` (~line 4047): wait for `viewportStable` Completer instead of timer
  - Delete: `_extendAutoScrollGuard`, `_scheduleRestoreVerify` methods
  - Timeout path (~line 4020): clear JS flag on timeout
  - dispose (~line 371): remove `_restoreVerifyTimer?.cancel()`

- [ ] **Step 1: Add `_viewportStableCompleter` field, remove `_restoreVerifyTimer`**

In the fields area around line 247-249, change:

```dart
  Completer<bool>? _scrollToNormOffsetCompleter;

  Timer? _restoreVerifyTimer;
```

To:

```dart
  Completer<bool>? _scrollToNormOffsetCompleter;
  Completer<void>? _viewportStableCompleter;
```

In `dispose()` around line 371, remove the line:

```dart
    _restoreVerifyTimer?.cancel();
```

- [ ] **Step 2: Register `viewportStable` JS handler**

In `onCreateWebView` handler registration area, after the `scrollToNormOffsetDone` handler (~line 1500), add:

```dart
        controller.addJavaScriptHandler(
          handlerName: 'viewportStable',
          callback: (data) {
            debugPrint('[hibiki-reader-pos] viewportStable received');
            final Completer<void>? c = _viewportStableCompleter;
            if (c != null && !c.isCompleted) {
              c.complete();
            }
          },
        );
```

- [ ] **Step 3: Add `_setJsRestoreFlag` / `_clearJsRestoreFlag` helpers**

After the `_markReaderContentReady` method (around line 1335), add:

```dart
  Future<void> _setJsRestoreFlag() async {
    if (!_controllerInitialised) return;
    try {
      await _controller.evaluateJavascript(
        source: 'window.__hoshiRestoreInFlight = true;',
      );
    } catch (_) {}
  }

  Future<void> _clearJsRestoreFlag() async {
    if (!_controllerInitialised) return;
    try {
      await _controller.evaluateJavascript(
        source: 'window.__hoshiRestoreInFlight = false;',
      );
    } catch (_) {}
  }
```

- [ ] **Step 4: Set JS flag in `_bootstrapRestoreReaderPos` when starting restore**

In `_bootstrapRestoreReaderPos`, after line 4003 (`_restoreInFlight = true;`), add:

```dart
    _restoreInFlight = true;
    await _setJsRestoreFlag();
```

- [ ] **Step 5: Rewrite `_finishRestore` — wait `viewportStable`, then unmask**

Replace the entire `_finishRestore` method (and delete `_extendAutoScrollGuard` and `_scheduleRestoreVerify`) with:

```dart
  /// consume `_pendingRestorePos`：调 JS 滚到章内归一化偏移。
  /// JS 滚动后通过 rAF 稳定性检测，连续 3 帧偏移不变后发 `viewportStable`。
  /// 收到 `viewportStable` 后清 `_restoreInFlight`、释放 JS 恢复锁、撤遮罩。
  Future<void> _finishRestore() async {
    final ReaderViewportPos? pending = _pendingRestorePos;
    if (pending == null) {
      _restoreInFlight = false;
      await _clearJsRestoreFlag();
      _markReaderContentReady();
      return;
    }
    _pendingRestorePos = null;
    try {
      _scrollToNormOffsetCompleter = Completer<bool>();
      _viewportStableCompleter = Completer<void>();
      await AudiobookBridge.scrollToNormOffset(
        _controller,
        section: pending.section,
        offset: pending.offset,
      );
      final bool scrollOk = await _scrollToNormOffsetCompleter!.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
      _scrollToNormOffsetCompleter = null;
      debugPrint(
        '[hibiki-reader-pos] scrolled s=${pending.section} '
        'o=${pending.offset} ok=$scrollOk',
      );
      if (scrollOk) {
        await _viewportStableCompleter!.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
        debugPrint('[hibiki-reader-pos] viewportStable reached');
      }
      _viewportStableCompleter = null;
    } catch (e) {
      debugPrint('[hibiki-reader-pos] scrollToNormOffset err: $e');
      _scrollToNormOffsetCompleter = null;
      _viewportStableCompleter = null;
    } finally {
      _restoreInFlight = false;
      await _clearJsRestoreFlag();
      _markReaderContentReady();
    }
  }
```

- [ ] **Step 6: Clear JS flag in all error/timeout paths**

In `_bootstrapRestoreReaderPos`, the 5-second timeout handler (~line 4020-4030), change:

```dart
      Future.delayed(const Duration(seconds: 5), () {
        if (_restoreInFlight && mounted) {
          debugPrint('[hibiki-reader-pos] restore timeout, clearing flags');
          _restoreInFlight = false;
          _pendingRestorePos = null;
          _inFlightNavSection = null;
          final Completer<bool>? c = _scrollToNormOffsetCompleter;
          if (c != null && !c.isCompleted) c.complete(false);
          _markReaderContentReady();
        }
      });
```

To:

```dart
      Future.delayed(const Duration(seconds: 5), () async {
        if (_restoreInFlight && mounted) {
          debugPrint('[hibiki-reader-pos] restore timeout, clearing flags');
          _restoreInFlight = false;
          _pendingRestorePos = null;
          _inFlightNavSection = null;
          final Completer<bool>? c = _scrollToNormOffsetCompleter;
          if (c != null && !c.isCompleted) c.complete(false);
          final Completer<void>? vc = _viewportStableCompleter;
          if (vc != null && !vc.isCompleted) vc.complete();
          await _clearJsRestoreFlag();
          _markReaderContentReady();
        }
      });
```

In the catch block of `_bootstrapRestoreReaderPos` (~line 4031-4037), change:

```dart
    } catch (e) {
      debugPrint('[hibiki-reader-pos] restore requestSectionNav err: $e');
      _restoreInFlight = false;
      _pendingRestorePos = null;
      _inFlightNavSection = null;
      _markReaderContentReady();
    }
```

To:

```dart
    } catch (e) {
      debugPrint('[hibiki-reader-pos] restore requestSectionNav err: $e');
      _restoreInFlight = false;
      _pendingRestorePos = null;
      _inFlightNavSection = null;
      unawaited(_clearJsRestoreFlag());
      _markReaderContentReady();
    }
```

- [ ] **Step 7: Keep the `_maybeInjectAudiobookBridge` restore-in-flight guard**

Confirm the existing guard (from the current session's Fix 2) is still in place:

```dart
    _audiobookBridgeInjecting = true;
    try {
      debugPrint('[hibiki-audiobook] injecting via $trigger restoreInFlight=$_restoreInFlight');
      if (!_restoreInFlight) {
        _didRestorePos = false;
        _readerContentReady = false;
      }
      _lastSasayakiAppliedSection = -1;
      await _injectAudiobookBridge(controller);
      await _bootstrapCurrentTtuSection(controller);
      if (!_restoreInFlight) {
        await _bootstrapRestoreReaderPos();
      }
```

No change needed — just verify it's still there.

- [ ] **Step 8: flutter analyze**

```bash
cd d:/APP/vs_claude_code/hibiki/hibiki && flutter analyze
```

Expected: no new errors (only pre-existing info warnings).

- [ ] **Step 9: Build APK**

```bash
cd d:/APP/vs_claude_code/hibiki/hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64
```

- [ ] **Step 10: Commit hibiki**

```bash
cd d:/APP/vs_claude_code/hibiki/hibiki && git add -A && git commit -m "fix(reader): signal-driven position restore — __hoshiRestoreInFlight guard + viewportStable rAF"
```

---

### Task 4: Code review

- [ ] **Step 1: Dispatch code-reviewer subagent**

Review the ttu fork commit and hibiki commit together against this plan. Focus on:
- JS `waitStable` rAF loop: does it handle all exit conditions (max frames, drift retry, stable)?
- Dart `_finishRestore`: does every code path clear `__hoshiRestoreInFlight` and call `_markReaderContentReady`?
- Are there paths where `_restoreInFlight` stays true forever (leaked state)?
- Does the `viewportStable` handler correctly handle stale completers?
