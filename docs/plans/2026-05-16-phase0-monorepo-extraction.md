# Phase 0: Monorepo Extraction & Core Package Setup

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the existing Hibiki Flutter app into a melos monorepo with 5 packages, enabling multi-platform support while keeping Android fully functional.

**Architecture:** Extract platform-independent logic into shared packages (`hibiki_core`, `hibiki_dictionary`, `hibiki_anki`, `hibiki_audio`, `hibiki_platform`). The existing `hibiki/hibiki/` app becomes the Android shell that imports these packages via path dependency. No functionality change — pure structural refactoring.

**Tech Stack:** Flutter 3.41.6, Dart 3.11.4, melos (workspace management), Drift (SQLite), Riverpod (DI), dart:ffi (hoshidicts)

**Design Spec:** `docs/specs/2026-05-16-multiplatform-design.md`

**Scope:** This plan covers Phase 0 only (3-4 weeks). Phases 1-4 (Windows/macOS/iOS/Polish) get their own plans after Phase 0 is verified.

---

## File Structure Map

After Phase 0, the repo will look like:

```
hibiki/                              # repo root
├── packages/
│   ├── hibiki_core/
│   │   ├── pubspec.yaml
│   │   └── lib/
│   │       ├── hibiki_core.dart          # barrel export
│   │       └── src/
│   │           ├── database/             # Drift tables, database class, DAOs
│   │           ├── models/               # Shared data models
│   │           ├── language/             # LanguageConfig abstract interface ONLY (no dict dependency)
│   │           └── i18n/                 # Slang source JSON + generated strings (deferred — stays in app during Phase 0)
│   ├── hibiki_dictionary/
│   │   ├── pubspec.yaml
│   │   └── lib/
│   │       ├── hibiki_dictionary.dart    # barrel export
│   │       └── src/
│   │           ├── engine/               # DictionaryEngine interface + hoshidicts impl
│   │           ├── ffi/                  # hoshidicts FFI bindings
│   │           ├── formats/              # Yomichan, MDict, etc.
│   │           ├── language/             # Language implementations (Japanese, Chinese, English)
│   │           └── models/               # DictEntry, SearchResult, etc.
│   ├── hibiki_anki/
│   │   ├── pubspec.yaml
│   │   └── lib/
│   │       ├── hibiki_anki.dart          # barrel export
│   │       └── src/
│   │           ├── anki_service.dart     # Abstract interface
│   │           ├── anki_models.dart      # AnkiNote, DeckInfo, ModelInfo
│   │           ├── ankidroid/            # Android MethodChannel implementation
│   │           └── ankiconnect/          # HTTP client (for future desktop)
│   ├── hibiki_audio/
│   │   ├── pubspec.yaml
│   │   └── lib/
│   │       ├── hibiki_audio.dart         # barrel export
│   │       └── src/
│   │           ├── player/               # Audio player abstraction (just_audio wrapper)
│   │           ├── recorder/             # Recording abstraction
│   │           ├── audiobook/            # Audiobook controller, bridge, matching
│   │           ├── parsers/              # SRT/LRC/VTT/ASS/SMIL/JSON parsers (depend on AudioCue + text_file_io)
│   │           └── cue/                  # Cue models, alignment, normalization
│   └── hibiki_platform/
│       ├── pubspec.yaml
│       └── lib/
│           ├── hibiki_platform.dart      # barrel export
│           └── src/
│               ├── tts_engine.dart       # Abstract TTS interface
│               ├── platform_integration.dart  # Abstract intent/sharing/wakelock
│               └── storage_paths.dart    # Abstract storage paths
├── hibiki/                               # Android app (stays in place during Phase 0; move to apps/android/ deferred to Phase 1+)
├── native/
│   └── hoshidicts/                       # C++ source (moved from android/app/src/main/cpp/); includes built-in deinflector
├── melos.yaml
├── pubspec.yaml                          # workspace root
└── (existing: docs/, ci/, chisa/, .github/, etc.)
```

---

## Task 1: Melos Workspace Setup

**Files:**
- Create: `melos.yaml`
- Create: `pubspec.yaml` (workspace root)
- Create: `tool/bootstrap.ps1` (Windows workaround)
- Modify: `hibiki/pubspec.yaml` (upgrade file_picker)

> **IMPORTANT (已验证 2026-05-17):** 不使用 Dart 原生 `resolution: workspace`。
> 原因：unified resolution 会拉升 transitive Android deps（core:1.18.0, browser:1.9.0）要求 AGP 8.9.1+，
> 但当前 AGP 8.3.2 / Gradle 8.12 / Kotlin 1.9.23 构建正常，升级是全有或全无的巨大风险。
> 替代方案：melos `usePubspecOverrides: true` + 各包独立 path deps。

> **KNOWN BUG:** `melos bootstrap` 在 CJK Windows（中文/日文系统区域）崩溃（Dart VM subprocess
> stdout 编码为系统 locale 而非 UTF-8，melos 用 UTF-8 解码时报 FormatException）。
> Workaround: Windows 上用 `tool/bootstrap.ps1`，CI (Linux) 用 `dart run melos bootstrap`。

- [x] **Step 1: Create workspace root pubspec.yaml**

```yaml
name: hibiki_workspace
publish_to: none

environment:
  sdk: ">=3.5.0 <4.0.0"

dev_dependencies:
  melos: ^7.7.0
```

注意：无 `workspace:` 字段（不启用 Dart unified resolution）。

- [x] **Step 2: Create melos.yaml**

```yaml
name: hibiki_workspace
repository: https://github.com/hajisensai/hibiki

packages:
  - packages/*
  - hibiki

command:
  bootstrap:
    usePubspecOverrides: true

scripts:
  analyze:
    run: melos exec -- "dart analyze --fatal-infos"
  test:
    run: melos exec -- "flutter test"
  build:android:
    run: |
      cd hibiki && flutter build apk --release --target-platform android-arm64 --split-per-abi
```

- [x] **Step 3: Create Windows bootstrap script**

`tool/bootstrap.ps1` — runs `flutter pub get` in each package sequentially。

- [x] **Step 4: Upgrade file_picker ^5.3.0 → ^8.0.0**

Flutter 3.41.6 移除了 V1 plugin embedding（`PluginRegistry.Registrar`），file_picker 5.x/6.x 引用该类无法编译。
file_picker 8.x 仅使用 V2 embedding，dart analyze 通过。

- [x] **Step 5: Create empty package directories**

```powershell
$packages = @("hibiki_core", "hibiki_dictionary", "hibiki_anki", "hibiki_audio", "hibiki_platform")
foreach ($pkg in $packages) {
  New-Item -ItemType Directory -Force "packages/$pkg/lib/src"
}
```

- [x] **Step 6: Create package pubspec files**

Create `packages/hibiki_core/pubspec.yaml`:
```yaml
name: hibiki_core
description: Shared models, database, language config, and i18n for Hibiki
publish_to: none

environment:
  sdk: ">=3.5.0 <4.0.0"
  flutter: ">=3.41.6"

dependencies:
  flutter:
    sdk: flutter
  # 实际依赖在 Phase 0 文件迁移时按需添加（drift, path, collection 等）

dev_dependencies:
  flutter_test:
    sdk: flutter
```

Create `packages/hibiki_dictionary/pubspec.yaml`:
```yaml
name: hibiki_dictionary
description: Dictionary engine, FFI bindings, and language implementations for Hibiki
publish_to: none

environment:
  sdk: ">=3.5.0 <4.0.0"
  flutter: ">=3.41.6"

dependencies:
  flutter:
    sdk: flutter
  hibiki_core:
    path: ../hibiki_core
  # 实际依赖在文件迁移时按需添加（ffi, kana_kit, archive, dio, dart_mappable 等）

dev_dependencies:
  flutter_test:
    sdk: flutter
```

> **Note:** `dio` needed by `dictionary_downloader.dart`. `collection` used by language implementations. `dart_mappable` + builder needed for `structured_content.dart` (uses `@MappableClass` annotation, mapper is a `part of` file that needs regeneration after move).

Create `packages/hibiki_anki/pubspec.yaml`:
```yaml
name: hibiki_anki
description: Anki integration abstraction for Hibiki
publish_to: none

environment:
  sdk: ">=3.5.0 <4.0.0"
  flutter: ">=3.41.6"

dependencies:
  flutter:
    sdk: flutter
  hibiki_core:
    path: ../hibiki_core

dev_dependencies:
  flutter_test:
    sdk: flutter
```

Create `packages/hibiki_audio/pubspec.yaml`:
```yaml
name: hibiki_audio
description: Audio playback, recording, and subtitle parsers for Hibiki
publish_to: none

environment:
  sdk: ">=3.5.0 <4.0.0"
  flutter: ">=3.41.6"

dependencies:
  flutter:
    sdk: flutter
  hibiki_core:
    path: ../hibiki_core
  # 实际依赖在文件迁移时按需添加（just_audio, audio_service, record, path 等）

dev_dependencies:
  flutter_test:
    sdk: flutter
```

Create `packages/hibiki_platform/pubspec.yaml`:
```yaml
name: hibiki_platform
description: Platform service abstractions for Hibiki
publish_to: none

environment:
  sdk: ">=3.5.0 <4.0.0"
  flutter: ">=3.41.6"

dependencies:
  flutter:
    sdk: flutter
  hibiki_core:
    path: ../hibiki_core

dev_dependencies:
  flutter_test:
    sdk: flutter
```

- [x] **Step 7: Create barrel export files**

Create each `lib/<package_name>.dart`:

```dart
// packages/hibiki_core/lib/hibiki_core.dart
library hibiki_core;
// Exports will be added as files are moved in
```

(Same pattern for all 5 packages)

- [x] **Step 8: Bootstrap workspace**

```powershell
# Windows (CJK locale workaround):
powershell -ExecutionPolicy Bypass -File tool\bootstrap.ps1

# Linux/CI:
dart run melos bootstrap
```

已验证：所有 6 个包独立 `flutter pub get` 成功。

- [x] **Step 9: Verify Android build still works**

> **已验证 2026-05-17:** AGP 8.3.2 + Gradle 8.12 构建 debug APK 成功 (647 tasks, BUILD SUCCESSFUL)。
> file_picker ^8.0.0 兼容 Flutter 3.41.6（无 V1 embedding 引用）。
> media3-transformer 保持 1.10.0（原始版本，无需降级）。

```powershell
cd hibiki\android
.\gradlew.bat :app:assembleDebug
```

- [x] **Step 10: Verify tests pass**

```powershell
cd hibiki
flutter test
```

已验证：587/587 tests passed, flutter analyze 无 error。

- [ ] **Step 11: Commit**

```powershell
git add melos.yaml pubspec.yaml pubspec.lock packages/ tool/
git add hibiki/pubspec.yaml hibiki/pubspec.lock
git commit -m "chore: setup melos workspace with empty packages"
```

---

## Task 2: Extract hibiki_platform (Interfaces Only)

The thinnest package — just abstract interfaces. No file moves, just new files.

**Files:**
- Create: `packages/hibiki_platform/lib/src/tts_engine.dart`
- Create: `packages/hibiki_platform/lib/src/platform_integration.dart`
- Create: `packages/hibiki_platform/lib/src/storage_paths.dart`
- Modify: `packages/hibiki_platform/lib/hibiki_platform.dart`

- [ ] **Step 1: Write TtsEngine interface**

Create `packages/hibiki_platform/lib/src/tts_engine.dart`:

```dart
import 'dart:async';

abstract class TtsEngine {
  Future<void> speak(String text, {String? language});
  Future<void> stop();
  Future<List<String>> getAvailableLanguages();
  Future<bool> isAvailable();
}
```

- [ ] **Step 2: Write PlatformIntegration interface**

Create `packages/hibiki_platform/lib/src/platform_integration.dart`:

```dart
import 'dart:async';

abstract class PlatformIntegration {
  Stream<String> get incomingTextStream;
  Future<String?> pickFile({List<String>? allowedExtensions});
  Future<List<String>?> pickFiles({List<String>? allowedExtensions});
  Future<void> setWakeLock(bool enabled);
  Future<void> shareFile(String filePath, {String? mimeType});
}
```

- [ ] **Step 3: Write StoragePaths interface**

Create `packages/hibiki_platform/lib/src/storage_paths.dart`:

```dart
import 'dart:io';

abstract class StoragePaths {
  Directory get dictionaryDir;
  Directory get bookDir;
  Directory get audioDir;
  Directory get cacheDir;
  Directory get exportDir;
}
```

- [ ] **Step 4: Update barrel export**

Update `packages/hibiki_platform/lib/hibiki_platform.dart`:

```dart
library hibiki_platform;

export 'src/tts_engine.dart';
export 'src/platform_integration.dart';
export 'src/storage_paths.dart';
```

- [ ] **Step 5: Verify package resolves**

```powershell
cd packages/hibiki_platform
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat analyze
```

Expected: No issues found.

- [ ] **Step 6: Commit**

```powershell
git add packages/hibiki_platform/
git commit -m "feat(platform): add abstract platform service interfaces"
```

---

## Task 3: Extract hibiki_core — LanguageConfig Interface & Shared Models

Move platform-independent abstractions from the app into `hibiki_core`. This task is deliberately minimal: only the `LanguageConfig` abstract interface and shared data models.

> **Why no parsers here?** Testing confirmed ALL 6 parsers (srt, vtt, lrc, ass, smil, json_alignment) depend on `audiobook_model.dart` (`AudioCue` class) and `text_file_io.dart` (`flutter_charset_detector`). Additionally, vtt/lrc/ass parsers depend on `srt_parser.dart`, and srt_parser imports `audiobook_bridge.dart`. These files form a cohesive unit with the audiobook subsystem and belong in `hibiki_audio` (Task 7), NOT `hibiki_core`.

> **Why no Language implementations here?** `language.dart` imports `package:hibiki/dictionary.dart`, `package:hibiki/models.dart` (AppModel), `package:hibiki/utils.dart` (UI widgets), and `hoshidicts.dart`. Moving them to `hibiki_core` would create circular dependencies. They go to `hibiki_dictionary` in Task 5.

**Files:**
- Create: `packages/hibiki_core/lib/src/language/language_config.dart` (NEW: minimal abstract interface)
- Create: `packages/hibiki_core/lib/src/models/` (shared models if any emerge during extraction)
- Modify: `packages/hibiki_core/lib/hibiki_core.dart` (add exports)

- [ ] **Step 1: Create minimal LanguageConfig interface**

Create `packages/hibiki_core/lib/src/language/language_config.dart`:

```dart
import 'package:flutter/painting.dart';

/// Minimal language metadata interface — no dictionary operations.
/// Full Language class with lookup/deinflection lives in hibiki_dictionary.
abstract class LanguageConfig {
  String get languageName;
  String get languageCode;
  String get threeLetterCode;
  String get countryCode;
  TextDirection get textDirection;
  bool get preferVerticalReading;
  bool get isSpaceDelimited;
  TextBaseline get textBaseline;
  String get helloWorld;
  String get defaultFontFamily;
}
```

> **NOTE:** The full `Language` class with `textToWords()`, `prepareSearchResults()`, `wordFromIndex()` etc. stays in the app until Task 5 moves it to `hibiki_dictionary` where it can access hoshidicts.

- [ ] **Step 2: Update barrel export**

Update `packages/hibiki_core/lib/hibiki_core.dart`:
```dart
library hibiki_core;

// Language (interface only — implementations in hibiki_dictionary)
export 'src/language/language_config.dart';
```

- [ ] **Step 3: Verify hibiki_core compiles**

```powershell
cd packages/hibiki_core
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat analyze
```

- [ ] **Step 4: Add hibiki_core dependency to app**

In `hibiki/pubspec.yaml`, add:
```yaml
dependencies:
  hibiki_core:
    path: ../packages/hibiki_core
```

- [ ] **Step 5: Verify Android build**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

Expected: Build succeeds. No imports changed yet — Task 3 only adds the package as a dependency.

- [ ] **Step 6: Commit**

```powershell
git add packages/hibiki_core/ hibiki/pubspec.yaml
git commit -m "refactor(core): add LanguageConfig interface to hibiki_core"
```

---

## Task 4: Extract hibiki_core — Database

The most critical extraction. Drift database (tables, DAOs, generated code) moves to `hibiki_core`.

**Files:**
- Move: `hibiki/lib/src/database/database.dart` -> `packages/hibiki_core/lib/src/database/database.dart`
- Move: `hibiki/lib/src/database/tables.dart` -> `packages/hibiki_core/lib/src/database/tables.dart`
- Move: `hibiki/lib/src/database/database.g.dart` -> `packages/hibiki_core/lib/src/database/database.g.dart`
- Modify: `packages/hibiki_core/pubspec.yaml` (ensure drift deps)
- Modify: All app files that import database

- [ ] **Step 1: Copy database files**

```powershell
New-Item -ItemType Directory -Force "packages/hibiki_core/lib/src/database"
Copy-Item "hibiki/lib/src/database/database.dart" "packages/hibiki_core/lib/src/database/"
Copy-Item "hibiki/lib/src/database/tables.dart" "packages/hibiki_core/lib/src/database/"
Copy-Item "hibiki/lib/src/database/database.g.dart" "packages/hibiki_core/lib/src/database/"
```

- [ ] **Step 2: Fix database imports**

In the copied database files, update any `package:hibiki/...` imports to use relative paths or `package:hibiki_core/...`.

- [ ] **Step 3: Add database exports to barrel**

Append to `packages/hibiki_core/lib/hibiki_core.dart`:
```dart
// Database
export 'src/database/database.dart';
export 'src/database/tables.dart';
```

- [ ] **Step 4: Regenerate Drift code in hibiki_core**

```powershell
cd packages/hibiki_core
D:\flutter_sdk\flutter_extracted\flutter\bin\dart.bat run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 5: Update app to import database from package**

Find all files importing the old database path:
```powershell
rg "import.*database/database|import.*database/tables" hibiki/lib/ --files-with-matches
```

Update each to:
```dart
import 'package:hibiki_core/hibiki_core.dart';
```

- [ ] **Step 6: Verify Android build**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

- [ ] **Step 7: Commit**

```powershell
git add packages/hibiki_core/ hibiki/lib/ hibiki/pubspec.yaml
git commit -m "refactor(core): extract Drift database to hibiki_core"
```

---

## Task 5: Extract hibiki_dictionary (+ Language Implementations)

Move dictionary engine, FFI bindings, format handlers, AND language implementations (which depend on dictionary/hoshidicts).

**Files:**
- Move: `hibiki/lib/src/dictionary/hoshidicts.dart` -> `packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart`
- Move: `hibiki/lib/src/dictionary/hoshidicts_ffi_bindings.dart` -> `packages/hibiki_dictionary/lib/src/ffi/hoshidicts_ffi_bindings.dart`
- Move: `hibiki/lib/src/dictionary/dictionary.dart` -> `packages/hibiki_dictionary/lib/src/engine/dictionary.dart`
- Move: `hibiki/lib/src/dictionary/dictionary_entry.dart` -> `packages/hibiki_dictionary/lib/src/models/dictionary_entry.dart`
- Move: `hibiki/lib/src/dictionary/dictionary_search_result.dart` -> `packages/hibiki_dictionary/lib/src/models/dictionary_search_result.dart`
- Move: `hibiki/lib/src/dictionary/dictionary_format.dart` -> `packages/hibiki_dictionary/lib/src/formats/dictionary_format.dart`
- Move: `hibiki/lib/src/dictionary/dictionary_utils.dart` -> `packages/hibiki_dictionary/lib/src/engine/dictionary_utils.dart`
- Move: `hibiki/lib/src/dictionary/formats/` -> `packages/hibiki_dictionary/lib/src/formats/`
- Move: `hibiki/lib/src/dictionary/structured_content.dart` -> `packages/hibiki_dictionary/lib/src/models/structured_content.dart`
- Move: `hibiki/lib/src/language/language.dart` -> `packages/hibiki_dictionary/lib/src/language/language.dart`
- Move: `hibiki/lib/src/language/language_utils.dart` -> `packages/hibiki_dictionary/lib/src/language/language_utils.dart`
- Move: `hibiki/lib/src/language/implementations/` -> `packages/hibiki_dictionary/lib/src/language/implementations/`

> **NOTE: Language module extraction requires pre-work.** Analysis shows the coupling is narrow:
>
> **AppModel dependency (only 1 property used):**
> - `Language.getTermReadingOverrideWidget()` and `Language.getPitchWidget()` pass `AppModel appModel` as parameter
> - `JapaneseLanguage` only accesses `appModel.dictionaryFontSize` (a `double`)
> - Chinese/English implementations don't use AppModel at all
> - **Fix:** Replace `AppModel appModel` parameter with `double dictionaryFontSize` or define a 1-field interface
>
> **utils.dart dependency (only ErrorLogService):**
> - `language_utils.dart:141` uses `ErrorLogService.instance.log()` — move ErrorLogService to `hibiki_core`
> - Chinese/English import `utils.dart` but don't use any symbol — remove unused imports
>
> **Estimated effort: 1-2 days** (much less than originally feared)

- [ ] **Step 1: Create directory structure**

```powershell
New-Item -ItemType Directory -Force "packages/hibiki_dictionary/lib/src/engine"
New-Item -ItemType Directory -Force "packages/hibiki_dictionary/lib/src/ffi"
New-Item -ItemType Directory -Force "packages/hibiki_dictionary/lib/src/formats"
New-Item -ItemType Directory -Force "packages/hibiki_dictionary/lib/src/models"
New-Item -ItemType Directory -Force "packages/hibiki_dictionary/lib/src/language"
New-Item -ItemType Directory -Force "packages/hibiki_dictionary/lib/src/language/implementations"
```

- [ ] **Step 2: Copy FFI bindings**

```powershell
Copy-Item "hibiki/lib/src/dictionary/hoshidicts_ffi_bindings.dart" "packages/hibiki_dictionary/lib/src/ffi/"
Copy-Item "hibiki/lib/src/dictionary/hoshidicts.dart" "packages/hibiki_dictionary/lib/src/engine/"
```

- [ ] **Step 3: Fix FFI bindings Platform check**

In `packages/hibiki_dictionary/lib/src/ffi/hoshidicts_ffi_bindings.dart`, replace the Android-only check:

```dart
// Before
DynamicLibrary _openLib() {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libhoshidicts_ffi.so');
  }
  throw UnsupportedError('hoshidicts only supports Android');
}

// After
DynamicLibrary _openLib() {
  if (Platform.isAndroid) return DynamicLibrary.open('libhoshidicts_ffi.so');
  if (Platform.isWindows) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    return DynamicLibrary.open('$exeDir/hoshidicts_ffi.dll');
  }
  if (Platform.isMacOS) return DynamicLibrary.open('libhoshidicts_ffi.dylib');
  if (Platform.isIOS) return DynamicLibrary.process();
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}
```

- [ ] **Step 4: Copy remaining dictionary files**

```powershell
Copy-Item "hibiki/lib/src/dictionary/dictionary.dart" "packages/hibiki_dictionary/lib/src/engine/"
Copy-Item "hibiki/lib/src/dictionary/dictionary_entry.dart" "packages/hibiki_dictionary/lib/src/models/"
Copy-Item "hibiki/lib/src/dictionary/dictionary_search_result.dart" "packages/hibiki_dictionary/lib/src/models/"
Copy-Item "hibiki/lib/src/dictionary/dictionary_utils.dart" "packages/hibiki_dictionary/lib/src/engine/"
Copy-Item "hibiki/lib/src/dictionary/dictionary_format.dart" "packages/hibiki_dictionary/lib/src/formats/"
Copy-Item "hibiki/lib/src/dictionary/dictionary_operations_params.dart" "packages/hibiki_dictionary/lib/src/models/"
Copy-Item "hibiki/lib/src/dictionary/dictionary_downloader.dart" "packages/hibiki_dictionary/lib/src/engine/"
Copy-Item "hibiki/lib/src/dictionary/structured_content.dart" "packages/hibiki_dictionary/lib/src/models/"
Copy-Item "hibiki/lib/src/dictionary/structured_content.mapper.dart" "packages/hibiki_dictionary/lib/src/models/"
Copy-Item "hibiki/lib/src/dictionary/formats/*" "packages/hibiki_dictionary/lib/src/formats/"
```

- [ ] **Step 4b: Copy language files into hibiki_dictionary**

```powershell
Copy-Item "hibiki/lib/src/language/language.dart" "packages/hibiki_dictionary/lib/src/language/"
Copy-Item "hibiki/lib/src/language/language_utils.dart" "packages/hibiki_dictionary/lib/src/language/"
Copy-Item "hibiki/lib/src/language/implementations/*" "packages/hibiki_dictionary/lib/src/language/implementations/" -Recurse
```

- [ ] **Step 5: Fix internal imports in copied files**

Update all relative imports within the dictionary package to use the new paths. Update any `package:hibiki/...` imports to either:
- `package:hibiki_core/...` (for database, models, LanguageConfig)
- Relative imports within the package
- **For language files — specific decoupling steps (audited):**

  1. **`package:hibiki/dictionary.dart`** → internal relative import within hibiki_dictionary (e.g., `../models/dictionary_entry.dart`). All dictionary types (DictionaryEntry, DictionarySearchResult, DictionaryFormat, etc.) are now co-located in the same package.

  2. **`package:hibiki/language.dart`** → self-reference barrel, remove. Use relative imports.

  3. **`package:hibiki/models.dart`** (AppModel) → **Only `dictionaryFontSize: double` is used.** In `Language.getTermReadingOverrideWidget()` and `Language.getPitchWidget()`, change parameter from `required AppModel appModel` to `required double dictionaryFontSize`. JapaneseLanguage overrides access `appModel.dictionaryFontSize` at 4 locations (lines 218, 244, 275, 299) — change to use the new `double` parameter directly. Chinese/English don't reference AppModel at all.

  4. **`package:hibiki/utils.dart`** → Only `ErrorLogService.instance.log()` used in `language_utils.dart:141`. Move `ErrorLogService` to `hibiki_core`. Remove unused `utils.dart` imports from `chinese_language.dart` and `english_language.dart`.

  5. **`package:hibiki/src/dictionary/hoshidicts.dart`** → internal relative import within hibiki_dictionary.

- [ ] **Step 6: Update barrel export**

```dart
// packages/hibiki_dictionary/lib/hibiki_dictionary.dart
library hibiki_dictionary;

export 'src/engine/dictionary.dart';
export 'src/engine/hoshidicts.dart';
export 'src/engine/dictionary_utils.dart';
export 'src/engine/dictionary_downloader.dart';
export 'src/ffi/hoshidicts_ffi_bindings.dart';
export 'src/models/dictionary_entry.dart';
export 'src/models/dictionary_search_result.dart';
export 'src/models/dictionary_operations_params.dart';
export 'src/models/structured_content.dart';
export 'src/formats/dictionary_format.dart';

// Language (implementations live here because they depend on hoshidicts)
export 'src/language/language.dart';
export 'src/language/language_utils.dart';
export 'src/language/implementations/japanese_language.dart';
export 'src/language/implementations/chinese_language.dart';
export 'src/language/implementations/english_language.dart';
```

- [ ] **Step 7: Add dependency to app and verify**

In `hibiki/pubspec.yaml`:
```yaml
  hibiki_dictionary:
    path: ../packages/hibiki_dictionary
```

Update app imports, then:
```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

- [ ] **Step 8: Commit**

```powershell
git add packages/hibiki_dictionary/ hibiki/lib/ hibiki/pubspec.yaml
git commit -m "refactor(dictionary): extract dictionary engine to hibiki_dictionary"
```

---

## Task 6: Extract hibiki_anki

Move Anki models, repository, and create the abstract interface.

**Files:**
- Create: `packages/hibiki_anki/lib/src/anki_service.dart` (abstract interface)
- Move: `hibiki/lib/src/anki/anki_models.dart` -> `packages/hibiki_anki/lib/src/anki_models.dart`
- Move: `hibiki/lib/src/anki/anki_repository.dart` -> `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart`
- Move: `hibiki/lib/src/anki/lapis_preset.dart` -> `packages/hibiki_anki/lib/src/lapis_preset.dart`
- Keep: `hibiki/lib/src/anki/anki_view_model.dart` stays in app (UI layer ViewModel)
- Create: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart` (stub for future)

- [ ] **Step 1: Create AnkiService abstract interface**

Create `packages/hibiki_anki/lib/src/anki_service.dart`:

```dart
import 'dart:async';
import 'anki_models.dart';

abstract class AnkiService {
  Future<bool> isAvailable();
  Future<List<String>> getDeckNames();
  Future<List<String>> getModelNames();
  Future<List<String>> getModelFields(String modelName);
  Future<void> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
  });
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  });
}
```

- [ ] **Step 2: Copy existing Anki files**

```powershell
New-Item -ItemType Directory -Force "packages/hibiki_anki/lib/src/ankidroid"
Copy-Item "hibiki/lib/src/anki/anki_models.dart" "packages/hibiki_anki/lib/src/"
Copy-Item "hibiki/lib/src/anki/anki_repository.dart" "packages/hibiki_anki/lib/src/ankidroid/"
Copy-Item "hibiki/lib/src/anki/lapis_preset.dart" "packages/hibiki_anki/lib/src/"
```

- [ ] **Step 3: Create AnkiConnect stub**

Create `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart`:

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../anki_service.dart';

class AnkiConnectService implements AnkiService {
  final String host;
  final int port;

  AnkiConnectService({this.host = 'localhost', this.port = 8765});

  Future<dynamic> _request(String action, [Map<String, dynamic>? params]) async {
    final body = jsonEncode({
      'action': action,
      'version': 6,
      if (params != null) 'params': params,
    });
    final response = await http.post(
      Uri.parse('http://$host:$port'),
      body: body,
      headers: {'Content-Type': 'application/json'},
    );
    final result = jsonDecode(response.body);
    if (result['error'] != null) {
      throw AnkiConnectException(result['error'] as String);
    }
    return result['result'];
  }

  @override
  Future<bool> isAvailable() async {
    try {
      await _request('version');
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<String>> getDeckNames() async {
    final result = await _request('deckNames');
    return (result as List).cast<String>();
  }

  @override
  Future<List<String>> getModelNames() async {
    final result = await _request('modelNames');
    return (result as List).cast<String>();
  }

  @override
  Future<List<String>> getModelFields(String modelName) async {
    final result = await _request('modelFieldNames', {'modelName': modelName});
    return (result as List).cast<String>();
  }

  @override
  Future<void> addNote({
    required String deckName,
    required String modelName,
    required Map<String, String> fields,
    List<String>? tags,
    Map<String, String>? mediaFiles,
  }) async {
    await _request('addNote', {
      'note': {
        'deckName': deckName,
        'modelName': modelName,
        'fields': fields,
        if (tags != null) 'tags': tags,
      },
    });
  }

  @override
  Future<bool> isDuplicate({
    required String deckName,
    required String fieldName,
    required String fieldValue,
  }) async {
    final result = await _request('findNotes', {
      'query': 'deck:"$deckName" $fieldName:"$fieldValue"',
    });
    return (result as List).isNotEmpty;
  }
}

class AnkiConnectException implements Exception {
  final String message;
  AnkiConnectException(this.message);
  @override
  String toString() => 'AnkiConnectException: $message';
}
```

- [ ] **Step 4: Update barrel export and fix imports**

```dart
// packages/hibiki_anki/lib/hibiki_anki.dart
library hibiki_anki;

export 'src/anki_service.dart';
export 'src/anki_models.dart';
export 'src/lapis_preset.dart';
export 'src/ankiconnect/ankiconnect_service.dart';
```

- [ ] **Step 5: Add dep to app, update imports, verify build**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

- [ ] **Step 6: Commit**

```powershell
git add packages/hibiki_anki/ hibiki/lib/ hibiki/pubspec.yaml
git commit -m "refactor(anki): extract Anki integration to hibiki_anki with AnkiConnect stub"
```

---

## Task 7: Extract hibiki_audio

Move audiobook controller, matching, alignment code, AND parsers. The `media/audiobook/` directory has 37+ files — classify each:

> **Why parsers are here, not in hibiki_core:** Testing confirmed ALL 6 parsers depend on `audiobook_model.dart` (`AudioCue` class with bookUid, chapterHref, sentenceIndex, textFragmentId, text, startMs, endMs, audioFileIndex — 8 fields, NOT a generic SubtitleCue) and `text_file_io.dart` (`flutter_charset_detector` package). Additionally vtt/lrc/ass parsers depend on `srt_parser.dart`, and srt_parser imports `audiobook_bridge.dart`. These form a cohesive audiobook subsystem.

**Goes to `hibiki_audio` (business logic, no UI):**
- **Parsers**: srt_parser.dart, vtt_parser.dart, lrc_parser.dart, ass_parser.dart, smil_parser.dart, json_alignment_parser.dart
- **Parser support**: text_file_io.dart (charset detection, used by all parsers)
- **Core audiobook**: audiobook_controller.dart, audiobook_model.dart, audiobook_repository.dart
- **Bridge/storage**: audiobook_bridge.dart, audiobook_storage.dart, audiobook_health.dart
- **Matching/alignment**: audio_text_normalizer.dart, epub_srt_matcher.dart, epub_cue_matcher.dart, collection_audio_matcher.dart, sasayaki_match_codec.dart, sasayaki_rematch.dart, cues_to_epub.dart
- **SRT book**: srt_book_model.dart, srt_book_repository.dart
- **Position/stats**: reader_position_model.dart, reader_position_repository.dart, reading_statistic_model.dart, reading_time_tracker.dart
- **Other**: bookmark_repository.dart, favorite_sentence_repository.dart

**Stays in app (UI / platform-specific):**
- audiobook_import_dialog.dart, audiobook_play_bar.dart, book_import_dialog.dart
- floating_lyric_channel.dart (MethodChannel)
- highlight_bridge.dart (WebView bridge)
- lyrics_mode_html.dart (HTML generation for WebView)
- text_to_epub.dart (may depend on UI flow)
- reading_statistic_idb_reader.dart (TTU migration)
- ttu_idb_reader.dart (TTU migration)

**Files:**
- Move: Parsers + text_file_io -> `packages/hibiki_audio/lib/src/parsers/`
- Move: Core audiobook + cue files -> `packages/hibiki_audio/lib/src/audiobook/` and `cue/`
- Move: Model/repository files -> `packages/hibiki_audio/lib/src/audiobook/`
- Keep: UI dialog files, MethodChannel files, WebView bridge files stay in app
- Modify: `packages/hibiki_audio/lib/hibiki_audio.dart`

- [ ] **Step 1: Create directory structure and copy files**

```powershell
New-Item -ItemType Directory -Force "packages/hibiki_audio/lib/src/audiobook"
New-Item -ItemType Directory -Force "packages/hibiki_audio/lib/src/cue"
New-Item -ItemType Directory -Force "packages/hibiki_audio/lib/src/parsers"
New-Item -ItemType Directory -Force "packages/hibiki_audio/lib/src/player"

# Parsers (depend on audiobook_model + text_file_io)
$parsers = @(
  "srt_parser.dart",
  "vtt_parser.dart",
  "lrc_parser.dart",
  "ass_parser.dart",
  "smil_parser.dart",
  "json_alignment_parser.dart",
  "text_file_io.dart"
)
foreach ($p in $parsers) {
  Copy-Item "hibiki/lib/src/media/audiobook/$p" "packages/hibiki_audio/lib/src/parsers/"
}

# Core audiobook files
$audioFiles = @(
  "audiobook_controller.dart",
  "audiobook_model.dart",
  "audiobook_repository.dart",
  "audiobook_bridge.dart",
  "audiobook_storage.dart",
  "audiobook_health.dart"
)
foreach ($f in $audioFiles) {
  Copy-Item "hibiki/lib/src/media/audiobook/$f" "packages/hibiki_audio/lib/src/audiobook/"
}

# Cue/alignment files
$cueFiles = @(
  "audio_text_normalizer.dart",
  "epub_srt_matcher.dart",
  "epub_cue_matcher.dart",
  "collection_audio_matcher.dart",
  "sasayaki_match_codec.dart",
  "sasayaki_rematch.dart",
  "cues_to_epub.dart"
)
foreach ($f in $cueFiles) {
  Copy-Item "hibiki/lib/src/media/audiobook/$f" "packages/hibiki_audio/lib/src/cue/"
}
```

- [ ] **Step 2: Fix internal imports**

Update all `package:hibiki/...` imports in copied files to use:
- `package:hibiki_core/...` for database, models
- Relative imports within `hibiki_audio` (e.g., parser→audiobook_model is `../audiobook/audiobook_model.dart`)

> **IMPORTANT**: Parsers currently use `AudioCue` from `audiobook_model.dart`. Since both are now in `hibiki_audio`, use relative imports. Do NOT create a separate `SubtitleCue` class — `AudioCue` has 8 domain-specific fields that parsers populate directly.

- [ ] **Step 3: Update barrel export**

```dart
// packages/hibiki_audio/lib/hibiki_audio.dart
library hibiki_audio;

// Parsers
export 'src/parsers/srt_parser.dart';
export 'src/parsers/vtt_parser.dart';
export 'src/parsers/lrc_parser.dart';
export 'src/parsers/ass_parser.dart';
export 'src/parsers/smil_parser.dart';
export 'src/parsers/json_alignment_parser.dart';
export 'src/parsers/text_file_io.dart';

// Audiobook core
export 'src/audiobook/audiobook_controller.dart';
export 'src/audiobook/audiobook_model.dart';
export 'src/audiobook/audiobook_repository.dart';
export 'src/audiobook/audiobook_bridge.dart';
export 'src/audiobook/audiobook_storage.dart';

// Cue/alignment
export 'src/cue/audio_text_normalizer.dart';
export 'src/cue/epub_srt_matcher.dart';
export 'src/cue/epub_cue_matcher.dart';
export 'src/cue/collection_audio_matcher.dart';
```

- [ ] **Step 4: Add dep to app, update imports, verify build**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

- [ ] **Step 5: Commit**

```powershell
git add packages/hibiki_audio/ hibiki/lib/ hibiki/pubspec.yaml
git commit -m "refactor(audio): extract audiobook, parsers and cue matching to hibiki_audio"
```

---

## Task 8: Move hoshidicts C++ to native/

Relocate the C++ source from deep inside the Android project to a shared `native/` directory.

**Files:**
- Move: `hibiki/android/app/src/main/cpp/` -> `native/hoshidicts/`
- Modify: `hibiki/android/app/build.gradle` (update CMake path)

- [ ] **Step 1: Copy C++ source**

```powershell
New-Item -ItemType Directory -Force "native/hoshidicts"
Copy-Item "hibiki/android/app/src/main/cpp/*" "native/hoshidicts/" -Recurse
```

- [ ] **Step 2: Update Android build.gradle CMake path**

In `hibiki/android/app/build.gradle`, find the `externalNativeBuild` block and update:

```groovy
// Before
externalNativeBuild {
    cmake {
        path "src/main/cpp/CMakeLists.txt"
    }
}

// After
externalNativeBuild {
    cmake {
        path "../../../native/hoshidicts/CMakeLists.txt"
    }
}
```

- [ ] **Step 3: Verify Android build with new CMake path**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

- [ ] **Step 4: Remove old C++ directory (after confirming build)**

```powershell
Remove-Item "hibiki/android/app/src/main/cpp" -Recurse -Force
```

- [ ] **Step 5: Verify build again**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

- [ ] **Step 6: Commit**

```powershell
git add native/hoshidicts/ hibiki/android/app/build.gradle
git rm -r hibiki/android/app/src/main/cpp/
git commit -m "refactor: move hoshidicts C++ source to native/ for cross-platform compilation"
```

---

## Task 9: flutter_inappwebview 6.x Upgrade PoC

Evaluate upgrading from the custom fork to official 6.x. This is a spike — if it fails, document what broke and keep the fork.

**Files:**
- Modify: `hibiki/pubspec.yaml` (change inappwebview dependency)
- Modify: Reader page files (API changes)

- [ ] **Step 1: Document current fork customizations (file-level audit)**

```powershell
cd hibiki
rg "flutter_inappwebview" lib/ --files-with-matches
```

Create `docs/plans/inappwebview-6x-audit.md` with per-file analysis. Known usage map (from review):

| File | APIs Used | PoC Priority |
|------|----------|-------------|
| `dictionary_popup_webview.dart` | InAppWebView, 11 JS handlers, shouldInterceptRequest, ContextMenu | HIGH |
| `reader_hoshi_page.dart` | InAppWebView, evaluateJavascript, JS handlers | HIGH |
| `highlight_bridge.dart` | evaluateJavascript (CSS Highlights API injection) | MEDIUM |
| `audiobook_bridge.dart` | evaluateJavascript, JS handlers | MEDIUM |
| `ttu_idb_reader.dart` | HeadlessInAppWebView, IndexedDB access | LOW (migration only) |
| `reading_statistic_idb_reader.dart` | HeadlessInAppWebView | LOW (migration only) |
| `audiobook_play_bar.dart` | Controller passthrough | LOW |
| `main.dart` | HeadlessInAppWebView engine warm-up | MEDIUM |

For each file, list every API call with line numbers and check 6.x equivalent.

- [ ] **Step 2: Create a git branch for the PoC**

```powershell
git checkout -b poc/inappwebview-6x
```

- [ ] **Step 3: Update pubspec.yaml dependency**

Replace the git fork dependency with:
```yaml
  flutter_inappwebview: ^6.1.5
```

Run `flutter pub get`.

- [ ] **Step 4: Fix compilation errors**

6.x API changes to address:
- `InAppWebViewGroupOptions` -> separate platform options classes
- `URLRequest` vs `WebResourceRequest` changes
- `shouldInterceptRequest` handler signature changes
- `android:` / `ios:` nested options -> `InAppWebViewSettings`

Fix each compilation error iteratively.

- [ ] **Step 5: Test on Android emulator**

If compiles, install on emulator and test:
1. Open an EPUB -> does it render?
2. Tap a word -> does JS bridge fire?
3. Scroll -> does position sync?
4. Custom fonts/CSS -> do they load?
5. Text selection -> does dictionary popup appear?

- [ ] **Step 6: Document results**

Update `docs/plans/inappwebview-6x-audit.md` with:
- PASS/FAIL for each of the 6 custom points
- Any behavioral differences
- Required code changes

- [ ] **Step 7: Decision point**

If all 6 custom points work:
```powershell
git checkout develop
git merge poc/inappwebview-6x
git commit -m "feat(webview): upgrade flutter_inappwebview to 6.x"
```

If some fail:
```powershell
git checkout develop
# Keep branch for reference, document blockers
```

---

## Task 10: Final Verification & Cleanup

- [ ] **Step 1: Run full analyze across workspace**

```powershell
melos run analyze
```

Expected: No issues in any package.

- [ ] **Step 2: Full Android release build**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

Expected: APK produced at `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

- [ ] **Step 3: Install and smoke test on emulator**

Test critical paths:
- App launch -> home screen
- Import EPUB -> opens in reader
- Tap word -> dictionary lookup works
- Import dictionary (Yomitan format)
- Create Anki card
- Import audiobook + subtitle -> sync playback

- [ ] **Step 4: Remove temporary re-export bridge files**

Delete any files in `hibiki/lib/` that are just re-exporting from packages (created in Task 3 Step 9).

- [ ] **Step 5: Final build verification**

```powershell
cd hibiki
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze
D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat build apk --release --target-platform android-arm64 --split-per-abi
```

- [ ] **Step 6: Commit cleanup**

```powershell
git add -A
git commit -m "refactor: finalize Phase 0 monorepo extraction, remove bridge files"
```

- [ ] **Step 7: Tag milestone**

```powershell
git tag phase0-complete
```

---

## Verification Checklist (Phase 0 Exit Criteria)

- [ ] `melos bootstrap` succeeds
- [ ] `melos run analyze` — zero issues
- [ ] Android APK builds (`--release --split-per-abi`)
- [ ] Smoke test passes: book import, reading, dictionary, Anki, audiobook
- [ ] All 5 packages resolve and export correctly
- [ ] hoshidicts C++ compiles from `native/hoshidicts/`
- [ ] No `package:hibiki/src/database/`, `package:hibiki/src/dictionary/`, `package:hibiki/src/anki/`, `package:hibiki/src/language/`, or `package:hibiki/src/media/audiobook/{parser,text_file_io}` imports remain in app (all migrated to package imports)
- [ ] inappwebview 6.x PoC documented (PASS or documented blockers)

---

## Notes for Phase 1 Planning

After Phase 0 is verified, Phase 1 (Windows) will be planned as a separate document covering:
1. hoshidicts Windows DLL compilation (MSVC + CMake adaptation of `native/hoshidicts/`; deinflection is built-in, no separate MeCab needed)
2. flutter_inappwebview 6.x Windows WebView2 integration
3. Fluent Design UI shell (NavigationPane + pages)
4. AnkiConnect HTTP integration (using the stub from Task 6)
5. Windows packaging (MSIX)
