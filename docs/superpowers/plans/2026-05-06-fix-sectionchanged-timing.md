# Fix sectionChanged Timing — Root Cause

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `sectionChanged(auto=true)` fire AFTER DOM rendering is complete, so Dart's `_finishRestore()` → `scrollToNormOffset()` runs on ready DOM.

**Architecture:** The RxJS `currentSectionIndex$` fires synchronously when `sectionIndex$.next()` is called, but `sectionRenderCompleteGlobal$` fires after Svelte DOM update (paginated) / `requestAnimationFrame` (continuous). The `sectionChanged` console message currently emits from `currentSectionIndex$` — too early. Fix: when `auto=true`, defer the console message until `sectionRenderCompleteGlobal$` fires for that index. With this root fix, hibiki's position system works for all books, so the `__hoshiManagesPosition` conditional workaround is reverted.

**Tech Stack:** SvelteKit (ttu fork) / RxJS / Flutter InAppWebView

---

## Root Cause Diagram

```
currentSectionIndex$.next(idx)           ← synchronous
  └→ sectionChangeSub fires             ← sectionChanged console.log (TOO EARLY)
  
... Svelte DOM update / requestAnimationFrame ...

sectionRenderCompleteGlobal$.next(idx)   ← DOM ready (THIS is when Dart should act)
  └→ __ttuGoToSection promise resolves
```

**After fix:**
```
currentSectionIndex$.next(idx)           ← synchronous
  └→ sectionChangeSub fires             ← auto=true: subscribe to renderComplete, don't emit yet
  
... Svelte DOM update / requestAnimationFrame ...

sectionRenderCompleteGlobal$.next(idx)   ← DOM ready
  └→ __ttuGoToSection promise resolves
  └→ sectionChangeSub's deferred emit   ← sectionChanged console.log (CORRECT TIMING)
```

---

### Task 1: ttu fork — defer `sectionChanged` for auto nav

**Files:**
- Modify: `d:\ttu-fork\apps\web\src\routes\b\+page.svelte:1115-1134`

- [ ] **Step 1: Edit `sectionChangeSub`**

Replace lines 1115-1134 with:

```typescript
    const sectionChangeSub = currentSectionIndex$.pipe(skip(1)).subscribe((idx) => {
      if (idx < 0) return;
      const navFlags = window as unknown as {
        __sasayakiAutoNav?: boolean;
        __sasayakiRequestNav?: unknown;
        __hoshiAutoScrollInFlight?: boolean;
      };
      if (navFlags.__sasayakiRequestNav === undefined) {
        return;
      }
      const autoFlag =
        navFlags.__sasayakiAutoNav === true || navFlags.__hoshiAutoScrollInFlight === true;

      const emit = () =>
        console.log(
          JSON.stringify({
            'hibiki-message-type': 'sectionChanged',
            sectionIndex: idx,
            auto: autoFlag
          })
        );

      if (autoFlag) {
        let emitted = false;
        sectionRenderCompleteGlobal$.pipe(
          filter((i) => i === idx),
          take(1)
        ).subscribe(() => {
          if (!emitted) { emitted = true; emit(); }
        });
        setTimeout(() => {
          if (!emitted) { emitted = true; emit(); }
        }, 3000);
      } else {
        emit();
      }
    });
```

**Why `filter((i) => i === idx)`:** Ensures we wait for the *correct* section's render, not a stale emission.

**Why 3s timeout:** Safety net — if `sectionRenderCompleteGlobal$` never fires (e.g. ttu bug), still emit so Dart's 5s restore timeout can clean up gracefully.

- [ ] **Step 2: Build ttu fork**

```bash
cd /d/ttu-fork && pnpm build
```

- [ ] **Step 3: Copy build to hibiki assets**

```bash
rsync -a --delete --exclude='fonts/' /d/ttu-fork/apps/web/build/ /d/APP/vs_claude_code/hibiki/hibiki/assets/ttu-ebook-reader/
```

- [ ] **Step 4: Commit ttu fork**

```bash
cd /d/ttu-fork && git add -A && git commit -m "fix(reader): [hibiki] defer sectionChanged(auto) until DOM render complete"
```

---

### Task 2: hibiki — revert `__hoshiManagesPosition` workaround

**Files:**
- Modify: `d:\APP\vs_claude_code\hibiki\hibiki\lib\src\pages\implementations\reader_ttu_source_page.dart:1373-1377`

- [ ] **Step 1: Make `__hoshiManagesPosition` unconditional**

Change:
```dart
        if (_hasAudioSlot)
          UserScript(
            source: 'window.__hoshiManagesPosition = true;',
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
```
To:
```dart
        UserScript(
          source: 'window.__hoshiManagesPosition = true;',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
```

**Why:** With the root timing fix, hibiki's `_finishRestore` works on ready DOM for all books (audiobook and non-audiobook). The conditional was a workaround that delegated non-audiobook position restore to ttu's native system.

- [ ] **Step 2: flutter analyze**

```bash
cd d:/APP/vs_claude_code/hibiki/hibiki && flutter analyze
```

- [ ] **Step 3: Compile APK**

```bash
cd d:/APP/vs_claude_code/hibiki/hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64
```

- [ ] **Step 4: Commit hibiki**

```bash
git add -A && git commit -m "fix(reader): root-fix sectionChanged timing + revert __hoshiManagesPosition workaround"
```

---

### Task 3: Code review

- [ ] **Step 1: Dispatch code-reviewer subagent**

Review the ttu fork commit and hibiki commit together against this plan.
