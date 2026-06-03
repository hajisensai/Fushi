# T4 Effect Probes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 schema 全量覆盖测试里「改了 DB 却没探针证明真生效」的 33 个 UNVERIFIED + 5 个 FAIL 设置补齐确定性「真生效」测试，把可在 widget/unit 层观测的 16 个设置从「只写穿 DB」升级到「真生效已验证」，其余只能在真机/WebView 观测的归入集成测试 backlog（不静默丢弃）。

**Architecture:** 不动产品代码（被测功能均已工作）。每个设置加一个**确定性 effect 探针测试**：翻转设置 → 断言真实可观测输出（reader CSS 串 / themeNotifier 枚举·归一化标量 / EpubSpreadMap 分页结构 / calcPopupPosition 返回宽 / TagsField 返回串 / imageCache 旋钮 / SwipeDismissWrapper onDismiss / DebugLogService 捕获 / SyncManager·BackupService 门控）随之变。这些测试验证已工作功能，正常应直接 PASS；任何 FAIL = 发现真回归 bug，按 docs/BUGS.md 流程处置。生效探针分两类落点：能在现有领域测试文件里扩的就 `extend`，否则 `new` 独立文件，全部镜像仓库现有 fixture 范式。

**Tech Stack:** Flutter 3.44.0 / Dart 3.12.0；flutter_test（unit + widget）；drift `NativeDatabase.memory()` 内存库；现有 test helper（`test/helpers/test_platform_services.dart`、各领域已有 fixture）。本机 flutter：`D:/flutter_sdk/flutter_extracted/flutter/bin/flutter`。测试一律加 `--no-pub`。

**调查依据：** 分类工作流（38 设置追到消费点 + 假功能对抗确认 0 个）+ 骨架提取工作流（9 领域可编译骨架，sync 域已实跑 8/8 绿）。原始证据见会话记录；本计划每个任务的代码均经源码核实。

---

## 覆盖矩阵（本计划落地后）

| 设置 | 层 | 任务 | 测试落点 |
|---|---|---|---|
| Text Orientation / Font Kerning(V) / VPAL | T1 | T1 | `test/reader/reader_content_styles_test.dart`(extend) |
| Design System / UI size | T4-unit | T2 | `test/models/theme_notifier_test.dart`(extend) |
| Spread Mode | T4-unit | T3 | `test/epub/epub_spread_map_test.dart`(extend) |
| Popup max width | T4-unit | T4 | `test/pages/dictionary_popup_layer_test.dart`(extend) |
| Auto-add book title to tags | T4-unit | T5 | `test/creator/tags_field_auto_add_book_test.dart`(new) |
| Low Memory Mode | T4-unit | T6 | `test/models/app_model_low_memory_mode_test.dart`(new) |
| Swipe dismiss sensitivity | T4-unit | T7 | `test/widgets/swipe_dismiss_wrapper_test.dart`(extend) |
| Enable debug log | T4-unit | T8 | `test/utils/misc/debug_log_service_test.dart`(new) |
| Auto Sync / Sync Statistics / Sync Audiobook Position / Sync book files / Sync dictionaries | T4-unit | T9 | `test/sync/sync_gating_test.dart`(new) |
| **device/widget backlog**：Reverse navigation bar, Auto search, Remote lookup（T4 但需 widget/FFI harness）+ 19 device-only（popup.js / 原生通知 / Android-only 更新 / 音量键回调 / spread direction / wakelock 等） | device | T10 | 文档登记 + 覆盖测试诚实标注 |

落地后效果验证从「harness 内 14」+「专项 16」= **30/52 行真生效已验证**；剩余 ~22 归集成 backlog（明确登记，不静默截断）。

---

## Task T1: 阅读器竖排 CSS 探针（Text Orientation / Font Kerning(V) / VPAL）

**Files:**
- Modify/Test: `hibiki/test/reader/reader_content_styles_test.dart`（extend：把 group 粘到现有 `main()` 末尾、收尾 `}` 之前；文件顶部 import 已齐备，不新增 import）

**根因背景：** 这三项都进 `ReaderContentStyles.css()`，但被 `isVertical`（`writingMode.startsWith('vertical')`）门控，只在竖排输出。覆盖测试跑横排默认态故探不到——不是 bug，是探针没在竖排取样。

- [ ] **Step 1: 粘入 group（应直接通过）**

```dart
  group('ReaderContentStyles vertical-only CSS probes (T1)', () {
    Future<ReaderSettings> verticalSettings() async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('vertical-rl');
      return settings;
    }

    Future<ReaderSettings> horizontalSettings() async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final ReaderSettings settings = ReaderSettings(db);
      await settings.refreshFromDb();
      await settings.setWritingMode('horizontal-tb');
      return settings;
    }

    test('vertical upright orientation emits text-orientation: upright',
        () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setVerticalTextOrientation('upright');
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('text-orientation: upright;'));
      expect(css, isNot(contains('text-orientation: mixed;')));
    });

    test('vertical mixed orientation emits text-orientation: mixed', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setVerticalTextOrientation('mixed');
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('text-orientation: mixed;'));
      expect(css, isNot(contains('text-orientation: upright;')));
    });

    test('vertical kerning ON emits font-kerning: normal', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableVerticalFontKerning(true);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('font-kerning: normal !important;'));
    });

    test('vertical kerning OFF omits font-kerning declaration', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableVerticalFontKerning(false);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('font-kerning')));
    });

    test('vertical VPAL ON emits font-feature-settings vpal 1', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableFontVPAL(true);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains("font-feature-settings: 'vpal' 1 !important;"));
    });

    test('vertical VPAL OFF omits vpal feature setting', () async {
      final ReaderSettings settings = await verticalSettings();
      await settings.setEnableFontVPAL(false);
      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, isNot(contains('vpal')));
    });

    test('horizontal-tb gates out all three even with every toggle ON',
        () async {
      final ReaderSettings settings = await horizontalSettings();
      await settings.setVerticalTextOrientation('upright');
      await settings.setEnableVerticalFontKerning(true);
      await settings.setEnableFontVPAL(true);

      final String css = ReaderContentStyles.css(settings: settings);
      expect(css, contains('horizontal-tb'));
      expect(css, isNot(contains('text-orientation')));
      expect(css, isNot(contains('font-kerning')));
      expect(css, isNot(contains('vpal')));
    });
  });
```

- [ ] **Step 2: 运行**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/reader/reader_content_styles_test.dart --no-pub`（在 `hibiki/` 下）
Expected: PASS（7 个新 test 全绿）。若任一 FAIL → 三段 CSS 门控真回归了，按 BUGS.md 验真→根因修。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/reader/reader_content_styles_test.dart
git commit -m "test(reader): T1 vertical CSS effect probes (text-orientation/kerning/vpal)"
```

**坑：** setter 是异步 write-through Drift，必须 `await`（漏了读旧值假阴性）。absent 断言用宽 token（`text-orientation`/`font-kerning`/`vpal`）安全——通读 css() 这三 token 只在受门控三段出现；别与 writing-mode 字面 `vertical-rl` 的 `rl` 混淆（匹配的是独立 token）。纯内存 Drift，无平台 mock。

---

## Task T2: 主题 effect 探针（Design System / UI size）

**Files:**
- Modify/Test: `hibiki/test/models/theme_notifier_test.dart`（extend：两个 group 插到现有 `main()` 末尾、最后一个 group `});` 之后、main 结尾 `}` 之前）
- Import 追加（文件顶部 import 区）：`import 'package:hibiki/src/utils/app_ui_scale.dart';` 和 `import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';`（`PrefCodec` 已由现有 `import 'package:hibiki_core/hibiki_core.dart'` 提供，勿重复 import）

- [ ] **Step 1: 追加两条 import + 两个 group（应直接通过）**

```dart
  group('ThemeNotifier.designSystemTheme reflects design_system pref', () {
    test('design_system=cupertino → designSystemTheme is cupertino and is '
        'injected into ThemeData.extensions', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('cupertino'),
      });

      expect(notifier.designSystem, 'cupertino');
      expect(notifier.designSystemTheme, HibikiDesignSystem.cupertino);

      final HibikiDesignSystemTheme? lightExt =
          notifier.theme.extension<HibikiDesignSystemTheme>();
      expect(lightExt, isNotNull);
      expect(lightExt!.designSystem, HibikiDesignSystem.cupertino);

      final HibikiDesignSystemTheme? darkExt =
          notifier.darkTheme.extension<HibikiDesignSystemTheme>();
      expect(darkExt, isNotNull);
      expect(darkExt!.designSystem, HibikiDesignSystem.cupertino);
    });

    test('design_system=material → designSystemTheme is material', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('material'),
      });

      expect(notifier.designSystem, 'material');
      expect(notifier.designSystemTheme, HibikiDesignSystem.material);
      expect(
        notifier.theme.extension<HibikiDesignSystemTheme>()!.designSystem,
        HibikiDesignSystem.material,
      );
    });

    test('absent design_system → defaults to auto', () {
      notifier.loadFromPrefsSnapshot(<String, String>{});

      expect(notifier.designSystem, 'auto');
      expect(notifier.designSystemTheme, HibikiDesignSystem.auto);
      expect(
        notifier.theme.extension<HibikiDesignSystemTheme>()!.designSystem,
        HibikiDesignSystem.auto,
      );
    });

    test('explicit design_system=auto → designSystemTheme is auto', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('auto'),
      });

      expect(notifier.designSystem, 'auto');
      expect(notifier.designSystemTheme, HibikiDesignSystem.auto);
    });

    test('unknown design_system value → falls through to auto', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'design_system': PrefCodec.encode('fluent'),
      });

      expect(notifier.designSystem, 'fluent');
      expect(notifier.designSystemTheme, HibikiDesignSystem.auto);
    });
  });

  group('ThemeNotifier.appUiScale reflects app_ui_scale pref', () {
    test('app_ui_scale=1.5 → appUiScale is the in-range normalized value', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(1.5),
      });

      expect(notifier.appUiScale, 1.5);
      expect(notifier.appUiScale, HibikiAppUiScale.normalize(1.5));
    });

    test('out-of-range app_ui_scale=5.0 → clamped to maxScale (3.0)', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(5.0),
      });

      expect(HibikiAppUiScale.maxScale, 3.0);
      expect(notifier.appUiScale, HibikiAppUiScale.maxScale);
      expect(notifier.appUiScale, 3.0);
    });

    test('below-range app_ui_scale=0.1 → clamped to minScale (0.3)', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(0.1),
      });

      expect(HibikiAppUiScale.minScale, 0.3);
      expect(notifier.appUiScale, HibikiAppUiScale.minScale);
      expect(notifier.appUiScale, 0.3);
    });

    test('absent app_ui_scale → defaults to defaultScale (1.0)', () {
      notifier.loadFromPrefsSnapshot(<String, String>{});

      expect(HibikiAppUiScale.defaultScale, 1.0);
      expect(notifier.appUiScale, HibikiAppUiScale.defaultScale);
      expect(notifier.appUiScale, 1.0);
    });

    test('app_ui_scale stored as int → still normalized as double', () {
      notifier.loadFromPrefsSnapshot(<String, String>{
        'app_ui_scale': PrefCodec.encode(2),
      });

      expect(notifier.appUiScale, 2.0);
    });
  });
```

- [ ] **Step 2: 运行**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/models/theme_notifier_test.dart --no-pub`
Expected: PASS。FAIL → designSystemTheme switch / normalize 夹取范围 / _buildThemeData 的 extensions 注入回归。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/models/theme_notifier_test.dart
git commit -m "test(theme): effect probes for design_system + app_ui_scale"
```

**坑：** snapshot value 必须 `PrefCodec.encode(...)`（_get 内部 decode）；`app_ui_scale` 用 double 字面（5.0/1.5/0.1）避免类型误判。`loadFromPrefsSnapshot` 不 notify，纯读 getter，别复用现有 notifyCount 断言。`ThemeData.extension<...>()` 可空，先 isNotNull 再 `!`。常量从源码核实：minScale=0.3 / defaultScale=1.0 / maxScale=3.0。

---

## Task T3: Spread Mode 分页映射 effect 探针

**Files:**
- Modify/Test: `hibiki/test/epub/epub_spread_map_test.dart`（extend：新 test 追加进现有 `group('EpubSpreadMap', () { ... })` 内；顶部 import 与 `_makeBook` 工厂已存在）

- [ ] **Step 1: 追加 test（应直接通过）**

```dart
    test(
        'flipping Spread Mode off→on rebuilds the page map on the SAME book '
        '(identity singles → paired/forceAll)', () {
      final EpubBook book = _makeBook(
        count: 6,
        imageOnly: <bool>[true, true, true, true, true, true],
      );

      final EpubSpreadMap off = EpubSpreadMap.build(
        book: book,
        spreadMode: 'off',
        spreadDirection: 'rtl',
      );
      expect(off.length, 6, reason: 'off 模式必须是 N 个单页 identity');
      for (int i = 0; i < 6; i++) {
        expect(off.entryAt(i).chapterIndex, i);
        expect(off.entryAt(i).isSpread, isFalse);
        expect(off.entryAt(i).secondChapterIndex, isNull);
        expect(off.virtualPageForChapter(i), i);
      }

      final EpubSpreadMap on = EpubSpreadMap.build(
        book: book,
        spreadMode: 'on',
        spreadDirection: 'rtl',
      );

      expect(on.length, 4, reason: 'on 模式应配对 → 页数应少于 off');
      expect(on.length, lessThan(off.length));

      expect(on.entryAt(0).isSpread, isFalse);
      expect(on.entryAt(0).chapterIndex, 0);

      expect(on.entryAt(1).isSpread, isTrue);
      expect(on.entryAt(1).chapterIndex, 1);
      expect(on.entryAt(1).secondChapterIndex, 2);
      expect(on.entryAt(1).chapterIndices, <int>[1, 2]);

      expect(on.entryAt(2).isSpread, isTrue);
      expect(on.entryAt(2).chapterIndex, 3);
      expect(on.entryAt(2).secondChapterIndex, 4);

      expect(on.entryAt(3).isSpread, isFalse);
      expect(on.entryAt(3).chapterIndex, 5);

      expect(off.virtualPageForChapter(4), 4);
      expect(on.virtualPageForChapter(4), 2);
      expect(on.virtualPageForChapter(4), isNot(off.virtualPageForChapter(4)));

      final bool offHasAnySpread =
          List<int>.generate(off.length, (int v) => v)
              .any((int v) => off.entryAt(v).isSpread);
      final bool onHasAnySpread = List<int>.generate(on.length, (int v) => v)
          .any((int v) => on.entryAt(v).isSpread);
      expect(offHasAnySpread, isFalse);
      expect(onHasAnySpread, isTrue);
    });
```

- [ ] **Step 2: 运行**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/epub/epub_spread_map_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/epub/epub_spread_map_test.dart
git commit -m "test(epub): Spread Mode off→on rebuilds page map effect probe"
```

**坑：** `_makeBook` 的 image-only 分支用单 `<img>` 无文本（`isImageOnlyChapter==true`，依赖 package:html 真解析）。`_forceAll` 里 ch0 永远 single（`i==0` 短路），别期望封面被配对。build 纯静态工厂，无异步/DB/mock。`spreadDirection` 当前 off/on 路径不读，传 `'rtl'` 仅满足签名。

---

## Task T4: Popup max width 约束 effect 探针

**Files:**
- Modify/Test: `hibiki/test/pages/dictionary_popup_layer_test.dart`（extend：group 插到现有 `main()` 内、最后一个纯 `test(...)` 之后、第一个 `testWidgets(...)` 之前；import 已齐备）

- [ ] **Step 1: 追加 group（应直接通过）**

```dart
  group('calcPopupPosition maxWidth constraint', () {
    const Rect selectionRect = Rect.fromLTWH(400, 300, 40, 24);
    const Size screen = Size(1920, 1080);

    test('small maxWidth caps the popup width to <= maxWidth', () {
      final Rect popupRect = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 250,
      );

      expect(popupRect.width, lessThanOrEqualTo(250));
      expect(popupRect.width, 250);
      expect(popupRect.left, greaterThanOrEqualTo(0));
      expect(popupRect.right, lessThanOrEqualTo(1920));
    });

    test('larger maxWidth yields a wider popup, still bounded by available width',
        () {
      final Rect narrow = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 250,
      );
      final Rect wide = calcPopupPosition(
        selectionRect: selectionRect,
        screen: screen,
        maxWidth: 1000,
      );

      expect(wide.width, greaterThan(narrow.width));
      expect(wide.width, 1000);
      expect(wide.width, lessThanOrEqualTo(screen.width));
      expect(wide.right, lessThanOrEqualTo(screen.width));
    });
  });
```

- [ ] **Step 2: 运行**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/pages/dictionary_popup_layer_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/pages/dictionary_popup_layer_test.dart
git commit -m "test(popup): calcPopupPosition maxWidth constraint effect probe"
```

**坑：** 顶层纯函数，**别**包进 testWidgets。必须用大屏（1920）让 maxWidth 成为生效上界（`width = (screen.width - padding*2).clamp(0, maxWidth)`）；小屏会先把宽压到小于 maxWidth 使精确等值断言失败。

---

## Task T5: Auto-add book title to tags effect 探针（new）

**Files:**
- Create/Test: `hibiki/test/creator/tags_field_auto_add_book_test.dart`

- [ ] **Step 1: 新建文件（应直接通过）**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// Test seam: subclasses [AppModel] and overrides exactly the four members
/// [TagsField.onCreatorOpenAction] reads — [savedTags], [autoAddBookNameToTags],
/// [isMediaOpen] and [getCurrentMediaItem]. Nothing else is touched, so the
/// uninitialised [prefsRepo] / database late fields are never dereferenced.
class _FakeTagsAppModel extends AppModel {
  _FakeTagsAppModel({
    required this.fakeSavedTags,
    required this.fakeAutoAdd,
    required this.fakeMediaOpen,
    required this.fakeMediaItem,
  }) : super(testPlatformServices());

  final String fakeSavedTags;
  final bool fakeAutoAdd;
  final bool fakeMediaOpen;
  final MediaItem? fakeMediaItem;

  @override
  String get savedTags => fakeSavedTags;

  @override
  bool get autoAddBookNameToTags => fakeAutoAdd;

  @override
  bool get isMediaOpen => fakeMediaOpen;

  @override
  MediaItem? getCurrentMediaItem() => fakeMediaItem;
}

MediaItem _bookItem(String title) => MediaItem(
      mediaIdentifier: 'book/1',
      title: title,
      mediaTypeIdentifier: 'reader_hibiki',
      mediaSourceIdentifier: 'reader_hibiki',
      position: 0,
      duration: 0,
      canDelete: false,
      canEdit: false,
    );

void main() {
  final DictionaryEntry entry = DictionaryEntry(word: '本', reading: 'ほん');
  final CreatorModel creatorModel = CreatorModel();

  Future<String?> runAction(
    WidgetTester tester,
    AppModel appModel,
  ) async {
    String? result;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            result = TagsField.instance.onCreatorOpenAction(
              ref: ref,
              appModel: appModel,
              creatorModel: creatorModel,
              entry: entry,
              creatorJustLaunched: true,
              dictionaryName: null,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return result;
  }

  group('TagsField.onCreatorOpenAction — auto-add book title to tags', () {
    testWidgets('auto-add ON + media open: book title joins saved tags',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: 'jp',
        fakeAutoAdd: true,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('My Book'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'jp My_Book');
    });

    testWidgets('auto-add OFF: book title is NOT added even when media open',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: 'jp',
        fakeAutoAdd: false,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('My Book'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'jp');
      expect(out, isNot(contains('My_Book')));
    });

    testWidgets('no media open: only saved tags returned',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: 'jp',
        fakeAutoAdd: true,
        fakeMediaOpen: false,
        fakeMediaItem: null,
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'jp');
    });

    testWidgets('empty saved tags + auto-add: title becomes the only tag',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: '',
        fakeAutoAdd: true,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('Solo Title'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'Solo_Title');
    });

    testWidgets('title with tabs is sanitised to underscores',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: '',
        fakeAutoAdd: true,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('A\tB C'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'A_B_C');
    });

    testWidgets('duplicate book tag is not appended twice',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: 'jp My_Book',
        fakeAutoAdd: true,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('My Book'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'jp My_Book');
    });
  });
}
```

- [ ] **Step 2: 运行**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/creator/tags_field_auto_add_book_test.dart --no-pub`
Expected: PASS（6 case）。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/creator/tags_field_auto_add_book_test.dart
git commit -m "test(creator): auto-add book title to tags effect probe"
```

**坑：** 只 override 这 4 个成员，**别**触任何会解引用 `prefsRepo!`(null) / `_database`(late) 的成员，也别在构造里调 `initialise()`。`WidgetRef` 是 required 但 tags 路径不解引用——用 `ProviderScope`+`Consumer` 抓真 ref（故 testWidgets 非 test）。`MediaItem` 全 required 字段必须给全。仓库无 mockito/mocktail，子类 override 是唯一 mock 方式。去重按空格精确整 tag 匹配。

---

## Task T6: Low Memory Mode 内存策略 effect 探针（new）

**Files:**
- Create/Test: `hibiki/test/models/app_model_low_memory_mode_test.dart`（镜像 `test/models/app_model_audio_sources_test.dart` 的 path_provider mock + AppModel wiring 范式）

- [ ] **Step 1: 新建文件（应直接通过）**

```dart
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki_core/hibiki_core.dart';

import '../helpers/test_platform_services.dart';

HibikiDatabase _testDb() {
  return HibikiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_path_provider_lmm');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late int prevMaxSize;
  late int prevMaxSizeBytes;

  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late AppModel appModel;

  setUp(() async {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    prevMaxSize = cache.maximumSize;
    prevMaxSizeBytes = cache.maximumSizeBytes;

    db = _testDb();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_app_model_lmm');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    final ImageCache cache = PaintingBinding.instance.imageCache;
    cache.maximumSize = prevMaxSize;
    cache.maximumSizeBytes = prevMaxSizeBytes;
    prefs.dispose();
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  test(
      'setLowMemoryMode(true) shrinks dictionary history cap and image cache budget',
      () async {
    final ImageCache cache = PaintingBinding.instance.imageCache;

    await appModel.setLowMemoryMode(true);

    expect(appModel.lowMemoryMode, isTrue);
    expect(appModel.maximumDictionaryHistoryItems, 5);
    expect(cache.maximumSize, 50);
    expect(cache.maximumSizeBytes, 20 << 20);
  });

  test(
      'setLowMemoryMode(false) restores normal dictionary history cap and image cache budget',
      () async {
    final ImageCache cache = PaintingBinding.instance.imageCache;

    await appModel.setLowMemoryMode(true);
    await appModel.setLowMemoryMode(false);

    expect(appModel.lowMemoryMode, isFalse);
    expect(appModel.maximumDictionaryHistoryItems, 10);
    expect(cache.maximumSize, 1000);
    expect(cache.maximumSizeBytes, 100 << 20);
  });

  test('low memory mode persists to the database under low_memory_mode key',
      () async {
    await appModel.setLowMemoryMode(true);

    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.lowMemoryMode, isTrue);
    reloaded.dispose();
  });
}
```

- [ ] **Step 2: 运行**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/models/app_model_low_memory_mode_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/models/app_model_low_memory_mode_test.dart
git commit -m "test(model): Low Memory Mode memory-policy effect probe"
```

**坑：** `imageCache` 是进程级全局单例——setUp 存原值、tearDown 还原（否则污染 golden/widget 测试）。必须 `TestWidgetsFlutterBinding.ensureInitialized()`（PaintingBinding.instance）+ mock `path_provider`（AppModel 构造经 DefaultCacheManager）。`lowMemoryMode` getter 走 prefsRepo，必须 `wireLocalAudioForTesting(prefsRepo:...)`（只 wireDatabaseForTesting 不够）。别同时 import material 与 rendering。

---

## Task T7: Swipe dismiss sensitivity 阈值 effect 探针

**Files:**
- Modify/Test: `hibiki/test/widgets/swipe_dismiss_wrapper_test.dart`（extend：group 插到 `main()` 内、现有 `group('SwipeDismissWrapper', ...)` 之后；import 已齐备）

- [ ] **Step 1: 追加 group（应直接通过）**

```dart
  group('SwipeDismissWrapper sensitivity changes dismiss threshold', () {
    Widget buildSingle({
      required Key childKey,
      required VoidCallback onDismiss,
      required double sensitivity,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SwipeDismissWrapper(
            sensitivity: sensitivity,
            onDismiss: onDismiss,
            child: SizedBox(
              key: childKey,
              width: 300,
              height: 100,
              child: const ColoredBox(color: Colors.green),
            ),
          ),
        ),
      );
    }

    // 纯水平拖动 100px：高灵敏 0.9 阈值 46 → 触发；低灵敏 0.1 阈值 174 → 不触发。
    const double dragDistance = 100;

    Future<bool> dragAndReportDismiss(
      WidgetTester tester, {
      required double sensitivity,
    }) async {
      bool dismissed = false;
      const childKey = ValueKey<String>('swipe-child');
      await tester.pumpWidget(
        buildSingle(
          childKey: childKey,
          onDismiss: () => dismissed = true,
          sensitivity: sensitivity,
        ),
      );

      final center = tester.getCenter(find.byKey(childKey));
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(dragDistance, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      return dismissed;
    }

    testWidgets('high sensitivity (0.9) dismisses on a 100px horizontal drag',
        (tester) async {
      final dismissed = await dragAndReportDismiss(tester, sensitivity: 0.9);
      expect(dismissed, isTrue);
    });

    testWidgets('low sensitivity (0.1) does NOT dismiss on the same 100px drag',
        (tester) async {
      final dismissed = await dragAndReportDismiss(tester, sensitivity: 0.1);
      expect(dismissed, isFalse);
    });

    testWidgets('same drag distance: high sensitivity fires, low does not',
        (tester) async {
      final highFired = await dragAndReportDismiss(tester, sensitivity: 0.9);
      final lowFired = await dragAndReportDismiss(tester, sensitivity: 0.1);
      expect(highFired, isTrue);
      expect(lowFired, isFalse);
      expect(highFired, isNot(equals(lowFired)));
    });
  });
```

- [ ] **Step 2: 运行**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/widgets/swipe_dismiss_wrapper_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/widgets/swipe_dismiss_wrapper_test.dart
git commit -m "test(widget): swipe-dismiss sensitivity threshold effect probe"
```

**坑：** `onDismiss` 只在 `onPointerUp` 判定，必须 startGesture→moveBy→up 完整序列 + pumpAndSettle。必须纯水平 `Offset(100,0)`（`_isHorizontal` 要 dragX>dragY*2.5）。距离 100 刻意卡在两阈值间（46<100<174）；改距离需重算。每次只 pump 单 wrapper + ValueKey 定位 child（避免 SizedBox 歧义）。

---

## Task T8: Enable debug log effect 探针（new）

**Files:**
- Create/Test: `hibiki/test/utils/misc/debug_log_service_test.dart`

**根因背景：** 覆盖测试里这项 FAIL（changed=false），因为它走 SharedPreferences + `DebugLogService.instance` 单例，不进 settings DB，`db.getAllPrefs()` 看不到。本单测单独守护。

- [ ] **Step 1: 新建文件（应直接通过）**

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/debug_log_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Verifies system/"Enable debug log" really takes effect: the toggle drives a
/// DebugLogService singleton (backed by SharedPreferences, NOT the settings DB),
/// and flipping it changes the observable capture behaviour of debugPrint.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await DebugLogService.instance.init();
    await DebugLogService.instance.setEnabled(false);
  });

  tearDown(() async {
    await DebugLogService.instance.setEnabled(false);
  });

  test('toggling enabled flips debugPrint capture and clears on disable',
      () async {
    final DebugLogService svc = DebugLogService.instance;

    expect(svc.enabled, isFalse);
    expect(svc.entries, isEmpty);

    debugPrint('captured-while-disabled-should-not-appear');
    expect(svc.entries, isEmpty);

    await svc.setEnabled(true);
    expect(svc.enabled, isTrue);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('debug_log_enabled'), isTrue);

    const String marker = 'hibiki-debug-marker-7f3a';
    debugPrint(marker);
    expect(svc.entries, isNotEmpty);
    expect(svc.entries.last.message, marker);
    expect(svc.getFullLog(), contains(marker));

    final int countBeforeNull = svc.entries.length;
    debugPrint(null);
    expect(svc.entries.length, countBeforeNull);

    await svc.setEnabled(false);
    expect(svc.enabled, isFalse);
    expect(svc.entries, isEmpty);

    debugPrint('post-disable-should-not-capture');
    expect(svc.entries, isEmpty);
  });
}
```

- [ ] **Step 2: 运行**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/utils/misc/debug_log_service_test.dart --no-pub`
Expected: PASS。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/utils/misc/debug_log_service_test.dart
git commit -m "test(utils): Enable debug log capture effect probe (SharedPreferences singleton)"
```

**坑：** 单例跨测试污染——setUp 归零 + tearDown `setEnabled(false)`。debugPrint 拦截只在 `init()` 安装钩子后生效（幂等）。必须 `TestWidgetsFlutterBinding.ensureInitialized()`（notifyListenersFrameSafe 读 SchedulerBinding）+ `SharedPreferences.setMockInitialValues`。只走非空路径（避开 getFullLog 空态 i18n）。

---

## Task T9: Sync 门控行为 effect 探针（new，5 项）

**Files:**
- Create/Test: `hibiki/test/sync/sync_gating_test.dart`（镜像 `test/sync/sync_manager_folder_cache_test.dart` 的 fake `SyncBackend` + `test/sync/backup_service_test.dart` 的 on-disk db / ZipDecoder 范式）

> 注：本骨架已被骨架提取 agent 在临时 scratch 文件实跑过 8/8 全绿（项目 Flutter 3.44.0，`--no-pub`），跑后删除 scratch、未改任何仓库文件。

- [ ] **Step 1: 新建文件（应直接通过）**

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_manager.dart';
import 'package:hibiki/src/sync/sync_repository.dart';
import 'package:hibiki/src/sync/ttu_models.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

/// Recording fake [SyncBackend]: drives `syncBook` through a successful EXPORT
/// so we can observe which sync channels each gate opens. Unrelated members
/// throw so an accidental code-path change fails loudly.
class _RecordingExportBackend implements SyncBackend {
  _RecordingExportBackend({this.remoteFiles = const DriveSyncFiles()});

  final DriveSyncFiles remoteFiles;

  int updateStatsCalls = 0;
  int updateProgressCalls = 0;
  int updateAudioBookCalls = 0;
  String? lastStatsFileId;
  String? lastAudioBookFileId;

  @override
  Future<String> findOrCreateRootFolder() async => 'root';

  @override
  Future<String> ensureBookFolder({
    required String bookTitle,
    required String rootFolderId,
    Uint8List? coverData,
  }) async =>
      'folder';

  @override
  Future<DriveSyncFiles> listSyncFiles(String folderId) async => remoteFiles;

  @override
  Future<void> updateProgressFile({
    required String folderId,
    required String? fileId,
    required TtuProgress progress,
  }) async {
    updateProgressCalls++;
  }

  @override
  Future<void> updateStatsFile({
    required String folderId,
    required String? fileId,
    required List<TtuStatistics> stats,
  }) async {
    updateStatsCalls++;
    lastStatsFileId = fileId;
  }

  @override
  Future<List<TtuStatistics>> getStatsFile(String fileId) async => const [];

  @override
  Future<void> updateAudioBookFile({
    required String folderId,
    required String? fileId,
    required TtuAudioBook audioBook,
  }) async {
    updateAudioBookCalls++;
    lastAudioBookFileId = fileId;
  }

  @override
  void clearCache() {}
  @override
  void restoreCache(
      {String? rootFolderId, Map<String, String>? titleToFolderId}) {}
  @override
  String? get cachedRootFolderId => 'root';
  @override
  Map<String, String> get cachedFolderIds => const <String, String>{};
  @override
  void cacheBookFolderIds(List<DriveFile> folders) {}

  @override
  Future<bool> get isAuthenticated async => true;
  @override
  Future<String?> get currentEmail async => null;
  @override
  Future<void> authenticate({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<void> signOut({required SyncRepository repo}) async =>
      throw UnimplementedError();
  @override
  Future<bool> restoreAuth(SyncRepository repo) async => true;
  @override
  Future<void> refreshAuth() async {}
  @override
  Future<List<DriveFile>> listBooks(String rootFolderId) async =>
      throw UnimplementedError();
  @override
  Future<TtuProgress> getProgressFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<TtuAudioBook> getAudioBookFile(String fileId) async =>
      throw UnimplementedError();
  @override
  Future<void> uploadContentFile({
    required String folderId,
    required String fileName,
    required File file,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<void> downloadContentFile({
    required String fileId,
    required File destination,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();
  @override
  Future<DriveFile?> findContentFile(String folderId, String fileName) async =>
      throw UnimplementedError();
}

Future<EpubBookRow> _seedBookWithPosition(HibikiDatabase db) async {
  await db.insertEpubBook(EpubBooksCompanion.insert(
    title: 'Book',
    epubPath: '/fake/book.epub',
    extractDir: '/fake/extract',
    chapterCount: 1,
    chaptersJson: '[{"characters":100}]',
    importedAt: DateTime.now().millisecondsSinceEpoch,
  ));
  final EpubBookRow book = (await db.getAllEpubBooks()).single;
  await db.upsertReaderPosition(ReaderPositionsCompanion(
    ttuBookId: Value(book.id),
    sectionIndex: const Value(0),
    normCharOffset: const Value(5000),
    ttuCharOffset: const Value(-1),
    updatedAt: const Value(1000),
  ));
  await db.setReadingStatistic(ReadingStatisticsCompanion.insert(
    title: 'Book',
    dateKey: '2026-06-03',
    charactersRead: 50,
    readingTimeMs: 60000,
    lastStatisticModified: 1000,
  ));
  return book;
}

void main() {
  group('SyncRepository gating toggles (defaults + flip)', () {
    late HibikiDatabase db;
    late SyncRepository repo;

    setUp(() {
      db = _memDb();
      repo = SyncRepository(db);
    });
    tearDown(() => db.close());

    test('Auto Sync defaults off, flips on', () async {
      expect(await repo.isAutoSyncEnabled(), isFalse);
      await repo.setAutoSyncEnabled(true);
      expect(await repo.isAutoSyncEnabled(), isTrue);
    });

    test('Sync Statistics defaults on, flips off', () async {
      expect(await repo.isSyncStatsEnabled(), isTrue);
      await repo.setSyncStatsEnabled(false);
      expect(await repo.isSyncStatsEnabled(), isFalse);
    });

    test('Sync Audiobook Position defaults on, flips off', () async {
      expect(await repo.isSyncAudioBookEnabled(), isTrue);
      await repo.setSyncAudioBookEnabled(false);
      expect(await repo.isSyncAudioBookEnabled(), isFalse);
    });

    test('Sync book files (content) defaults off, flips on', () async {
      expect(await repo.isSyncContentEnabled(), isFalse);
      await repo.setSyncContentEnabled(true);
      expect(await repo.isSyncContentEnabled(), isTrue);
    });

    test('Sync dictionaries defaults off, flips on', () async {
      expect(await repo.isSyncDictionaryEnabled(), isFalse);
      await repo.setSyncDictionaryEnabled(true);
      expect(await repo.isSyncDictionaryEnabled(), isTrue);
    });
  });

  group('syncBook honours the statistics gate', () {
    test('syncStats:false skips updateStatsFile', () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final EpubBookRow book = await _seedBookWithPosition(db);

      final backend = _RecordingExportBackend(
        remoteFiles: const DriveSyncFiles(
          statistics: DriveFile(id: 'remote-stats', name: 'statistics.json'),
        ),
      );
      final manager = SyncManager(db: db, backend: backend);

      final SyncBookResult result = await manager.syncBook(
        book: book,
        direction: SyncDirection.exportToTtu,
        syncStats: false,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
      );

      expect(result.direction, SyncResult.exported);
      expect(backend.updateProgressCalls, 1);
      expect(backend.updateStatsCalls, 0);
    });

    test('syncStats:true exports statistics using the discovered file id',
        () async {
      final HibikiDatabase db = _memDb();
      addTearDown(db.close);
      final EpubBookRow book = await _seedBookWithPosition(db);

      final backend = _RecordingExportBackend(
        remoteFiles: const DriveSyncFiles(
          statistics: DriveFile(id: 'remote-stats', name: 'statistics.json'),
        ),
      );
      final manager = SyncManager(db: db, backend: backend);

      final SyncBookResult result = await manager.syncBook(
        book: book,
        direction: SyncDirection.exportToTtu,
        syncStats: true,
        statsSyncMode: StatisticsSyncMode.merge,
        syncAudioBook: false,
      );

      expect(result.direction, SyncResult.exported);
      expect(backend.updateProgressCalls, 1);
      expect(backend.updateStatsCalls, 1);
      expect(backend.lastStatsFileId, 'remote-stats');
    });
  });

  group('exportBackup honours the dictionary gate', () {
    test('disabled omits dictionaryResources; enabled includes it', () async {
      final Directory dbDir =
          await Directory.systemTemp.createTemp('t4_dict_db_');
      final Directory dictDir =
          await Directory.systemTemp.createTemp('t4_dict_res_');
      final Directory outDir =
          await Directory.systemTemp.createTemp('t4_dict_out_');
      final HibikiDatabase onDiskDb = HibikiDatabase(dbDir.path);
      try {
        await Directory('${dictDir.path}/JMdict').create(recursive: true);
        await File('${dictDir.path}/JMdict/blobs.bin')
            .writeAsString('dictionary index');
        await onDiskDb.upsertDictionaryMeta(
          DictionaryMetadataCompanion.insert(
            name: 'JMdict',
            formatKey: 'yomichan',
            order: 0,
          ),
        );

        final service = BackupService(
          db: onDiskDb,
          dbDirectory: dbDir.path,
          dictionaryResourceDirectory: dictDir.path,
          appVersion: '1.0.0',
        );

        await SyncRepository(onDiskDb).setSyncDictionaryEnabled(false);
        final String offPath = '${outDir.path}/off.zip';
        await service.exportBackup(offPath);
        final offArchive =
            ZipDecoder().decodeBytes(await File(offPath).readAsBytes());
        expect(offArchive.findFile('dictionaryResources/JMdict/blobs.bin'),
            isNull);

        await SyncRepository(onDiskDb).setSyncDictionaryEnabled(true);
        final String onPath = '${outDir.path}/on.zip';
        await service.exportBackup(onPath);
        final onArchive =
            ZipDecoder().decodeBytes(await File(onPath).readAsBytes());
        expect(onArchive.findFile('dictionaryResources/JMdict/blobs.bin'),
            isNotNull);
      } finally {
        await onDiskDb.close();
        for (final Directory d in [dbDir, dictDir, outDir]) {
          if (d.existsSync()) await d.delete(recursive: true);
        }
      }
    });
  });
}
```

- [ ] **Step 2: 运行**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/sync/sync_gating_test.dart --no-pub`
Expected: PASS（8 test）。词典层会打印 drift "created the database multiple times" WARNING + stacktrace——无害（backup_service_test 同样触发），看最后一行 "All tests passed!"。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/sync/sync_gating_test.dart
git commit -m "test(sync): 5 sync gating toggles + stats/dictionary effect probes"
```

**坑：** 必须 `import 'dart:typed_data';`（fake backend 的 `ensureBookFolder` 用 `Uint8List?`）。词典层 `exportBackup` 内部 VACUUM INTO 会再开 on-disk 库，**必须用真实 `HibikiDatabase(dbDir.path)`，内存库会失败**。stats 导出三条件齐备：`direction:exportToTtu` + 有 ReaderPosition + 有 title==book.title 的 ReadingStatistics。`chaptersJson` 用含 `characters` 的非空数组让 totalCharacterCount>0。

---

## Task T10: device/widget backlog 登记 + 覆盖测试诚实标注

**Files:**
- Modify: `docs/specs/2026-06-03-test-flow-refactor-plan.md`（追加 backlog 小节）或本计划末尾「device backlog」段维护
- Modify: `hibiki/test/settings/settings_schema_coverage_test.dart`（给已被专项测试/设备 backlog 覆盖的设置加 known-coverage 标注，让 debug 输出不再对「别处已覆盖」的项裸喊 UNVERIFIED/FAIL）

**目的（no silent caps）：** 把不能在 widget 层观测的设置明确登记，不静默丢；覆盖测试输出要诚实指向「它在哪被验」。

- [ ] **Step 1: 在覆盖测试加一张 known-coverage 映射**

在 `settings_schema_coverage_test.dart` 顶部加一个常量 Map（key=`destId/Title`，value=覆盖它的测试或 backlog 标签），在 `_describe`/汇总 debugPrint 处用它把状态从 `UNVERIFIED`/`FAIL` 改成 `COVERED-ELSEWHERE: <ref>`：

```dart
/// 这些设置在 widget/unit 覆盖 harness 里观测不到「真生效」（消费点在真实
/// WebView popup.js / 原生通知 / Android-only 更新路径 / 音量键回调 / 单例
/// 不进 settings DB），但各自有专项测试或登记为设备集成 backlog。映射到证据，
/// 避免覆盖测试输出对「别处已覆盖」的项裸喊 UNVERIFIED/FAIL（no silent caps）。
const Map<String, String> kCoveredElsewhere = <String, String>{
  // 专项 unit/widget 测试（本计划 T1–T9）
  'reading/Text Orientation': 'test/reader/reader_content_styles_test.dart',
  'reading/Font Kerning (Vertical)': 'test/reader/reader_content_styles_test.dart',
  'reading/VPAL (Vertical Alt)': 'test/reader/reader_content_styles_test.dart',
  'appearance/Design System': 'test/models/theme_notifier_test.dart',
  'appearance/UI size': 'test/models/theme_notifier_test.dart',
  'reading/Spread Mode': 'test/epub/epub_spread_map_test.dart',
  'lookup/Popup max width': 'test/pages/dictionary_popup_layer_test.dart',
  'cardCreation/Auto-add book title to tags':
      'test/creator/tags_field_auto_add_book_test.dart',
  'system/Low Memory Mode': 'test/models/app_model_low_memory_mode_test.dart',
  'reading/Swipe dismiss sensitivity':
      'test/widgets/swipe_dismiss_wrapper_test.dart',
  'system/Enable debug log': 'test/utils/misc/debug_log_service_test.dart',
  'syncBackup/Auto Sync': 'test/sync/sync_gating_test.dart',
  'syncBackup/Sync Statistics': 'test/sync/sync_gating_test.dart',
  'syncBackup/Sync Audiobook Position': 'test/sync/sync_gating_test.dart',
  'syncBackup/Sync book files': 'test/sync/sync_gating_test.dart',
  'syncBackup/Sync dictionaries': 'test/sync/sync_gating_test.dart',
  // 设备/集成 backlog（消费点真机/WebView/Android-only，widget 测不到）
  'reading/Spread Direction': 'DEVICE: spread page order in WebView',
  'reading/Highlight text on tap': 'DEVICE: WebView onTap lookup',
  'reading/Tap empty area to hide controls': 'DEVICE: WebView onTapEmpty chrome',
  'reading/Invert swipe page turn direction': 'DEVICE: WebView swipe direction',
  'reading/Volume key page turning speed': 'DEVICE: native volume-key throttle',
  'reading/Keep screen awake': 'DEVICE: WakelockPlus channel',
  'reading/Volume button page turning': 'DEVICE: native VolumeKeyChannel',
  'reading/Invert volume buttons': 'DEVICE: native volume-key direction',
  'lookup/Pause on Lookup': 'DEVICE: audiobook pause on selection',
  'lookup/Aggregate word frequencies': 'DEVICE: popup.js frequency aggregation',
  'lookup/Auto search': 'WIDGET-TODO: HomeDictionaryPage debounce gate',
  'lookup/Remote dictionary lookup': 'INTEGRATION: remote host lookup',
  'lookup/Auto read word on lookup': 'DEVICE: TTS auto-read',
  'lookup/Collapse dictionaries': 'DEVICE: popup.js collapse',
  'lookup/Show expression tags': 'DEVICE: popup.js expression tags',
  'lookup/Deduplicate pitch accents': 'DEVICE: popup.js pitch dedup',
  'listening/Show media notification': 'DEVICE: native AudioHandler notification',
  'listening/Volume Key Sentence Navigation': 'DEVICE: native volume-key cue nav',
  'system/Update Channel': 'DEVICE: Android-only UpdateChecker (beta/stable)',
  "system/Don't remind me about updates": 'DEVICE: Android-only UpdateChecker',
  'system/Auto-install updates': 'DEVICE: Android-only UpdateChecker install',
  'appearance/Reverse navigation bar': 'WIDGET-TODO: HomePage nav order',
};
```

在汇总 debugPrint 之后追加：

```dart
    final List<ItemVerdict> stillUnaccounted = verdicts
        .where((ItemVerdict v) =>
            !v.effectVerified &&
            !kCoveredElsewhere.containsKey(v.id))
        .toList();
    for (final ItemVerdict v in stillUnaccounted) {
      debugPrint('[schema-coverage] STILL-UNACCOUNTED: ${v.id} '
          '(${v.controlType}) — 既无探针也未登记 backlog');
    }
    debugPrint('[schema-coverage] coverage accounting: '
        'effectVerified=${verdicts.where((ItemVerdict v) => v.effectVerified).length} '
        'coveredElsewhere=${verdicts.where((ItemVerdict v) => !v.effectVerified && kCoveredElsewhere.containsKey(v.id)).length} '
        'stillUnaccounted=${stillUnaccounted.length}');
```

并加一条断言守护（每个改了但没真生效的设置必须有去处）：

```dart
    expect(stillUnaccounted, isEmpty,
        reason: '每个 changed 但未 effect-verified 的设置都必须登记到 '
            'kCoveredElsewhere（专项测试或设备 backlog），不允许静默缺口。'
            '未登记: ${stillUnaccounted.map((ItemVerdict v) => v.id).join(", ")}');
```

- [ ] **Step 2: 运行覆盖测试确认账目齐全**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/settings/settings_schema_coverage_test.dart --no-pub`
Expected: PASS，且 `stillUnaccounted=0`。若有 STILL-UNACCOUNTED 行 → 把该设置补进 `kCoveredElsewhere`（或证明它该有探针）。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/settings/settings_schema_coverage_test.dart docs/specs/2026-06-03-t4-effect-probes-plan.md
git commit -m "test(settings): account every changed setting (probe or device backlog), no silent gaps"
```

**device/widget backlog 明细（22 项，供 Phase 2-4 集成测试消化）：**
- **WIDGET-TODO（可 widget 测但需 harness，本轮未做）：** Reverse navigation bar（HomePage nav 顺序翻转）、Auto search（HomeDictionaryPage debounce 门控）。
- **INTEGRATION：** Remote dictionary lookup（需本地 Hibiki 互联 host）。
- **DEVICE（真机/WebView/Android-only）：** Spread Direction、Highlight text on tap、Tap empty area、Invert swipe、Volume key speed、Keep screen awake、Volume button page turning、Invert volume buttons、Pause on Lookup、Aggregate frequencies、Auto read on lookup、Collapse dictionaries、Show expression tags、Deduplicate pitch accents、Show media notification、Volume Key Sentence Navigation、Update Channel、Don't remind、Auto-install。

---

## 全量回归

- [ ] **最终 Step: 跑全量测试确认无回归**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test --no-pub`（在 `hibiki/` 下）
Expected: 全绿。新增 ~40 个 effect 断言全部通过，现有测试无回归。

---

## Self-Review

**Spec 覆盖：** 33 UNVERIFIED + 5 FAIL = 38 设置全部有去处 —— 16 个 T1/T4-unit 专项测试（T1–T9），22 个 device/widget backlog 明确登记（T10），覆盖测试加断言守护「无静默缺口」。✅

**Placeholder 扫描：** 所有任务含完整可编译代码；run 命令含预期输出；无 TBD/TODO/「类似上面」。骨架均经源码核实，sync 域已实跑 8/8 绿。✅

**类型一致：** API 签名逐条从源码核实（ReaderSettings setter、ThemeNotifier getter、EpubSpreadMap.build、calcPopupPosition 命名参、TagsField.onCreatorOpenAction、AppModel.setLowMemoryMode、SwipeDismissWrapper、DebugLogService、SyncRepository/SyncManager/BackupService、SyncBackend 接口全员）。✅

**已知风险：**
- 这些测试验证**已工作**功能，正常应 PASS。任一 FAIL = 发现真回归 bug → 停下按 docs/BUGS.md 验真→根因修→再测，不要改测试迁就。
- imageCache（T6）、DebugLogService 单例（T8）有进程级污染风险，已在 setUp/tearDown 还原。
- T10 的 `kCoveredElsewhere` 是活清单：新增设置若既无探针也未登记，覆盖测试会 STILL-UNACCOUNTED 失败——这是有意的强制账目。
