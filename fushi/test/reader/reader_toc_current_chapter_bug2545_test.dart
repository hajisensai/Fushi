import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/ttu_toc_flatten.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2545：导航「章节列表」一行都不标当前章。
///
/// 目录是 spine 的**稀疏**映射：真实 EPUB 里同一章常横跨多个 xhtml（只有头一个
/// 进目录），章间插图页 / 扉页根本不在目录里。实测一本 35 项 spine 的文库本，
/// NCX 只指向 12 个 spine 位置 —— 读在剩下 23 个位置上的任何时刻，旧判据
/// 「当前 spine 章号 == 目录项 index」都不成立，于是整个列表没有勾、
/// `_currentTocRowKey` 也挂不上（「打开即滚到当前章」一起静默失效）。
///
/// 判据改成 floor（最后一个不晚于当前位置的目录项），与页脚章名
/// `ReaderFushiPage._currentChapterLabelFor` 和有声书面板「章节」tab 同一口径。
class _FakeInAppWebViewController implements InAppWebViewController {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppModel _testAppModel(FushiDatabase db) {
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  final AppModel appModel = AppModel(testPlatformServices())
    ..themeNotifier = themeNotifier;
  addTearDown(() async {
    themeNotifier.dispose();
    await db.close();
  });
  return appModel;
}

/// 截图那本书的形状：9 条目录，正文章各自横跨多个 spine 文件。
const List<TtuTocEntry> _sparseToc = <TtuTocEntry>[
  TtuTocEntry(index: 0, label: '表紙'),
  TtuTocEntry(index: 1, label: '目次'),
  TtuTocEntry(index: 2, label: '一章'),
  TtuTocEntry(index: 6, label: '二章'),
  TtuTocEntry(index: 10, label: '三章'),
  TtuTocEntry(index: 14, label: '奥付'),
];

void main() {
  // BUG-2580 起判据升级为 (章号, 章内偏移) 二元组的 resolveCurrentTocEntry，返回
  // 目录项下标；这里只给章号（偏移 null），floor 语义与 BUG-2545 时逐字同解。
  int? chapterOf(List<TtuTocEntry> toc, int? chapter) {
    final int? row = resolveCurrentTocEntry(toc, chapter, null);
    return row == null ? null : toc[row].index;
  }

  group('resolveCurrentTocEntry（BUG-2545 floor 语义）', () {
    test('稀疏目录：落在章内任意 spine 位置都解析到该章', () {
      // spine 3/4/5 都属于「一章」（index 2）——旧的精确相等在这三个位置全落空。
      for (final int chapter in <int>[2, 3, 4, 5]) {
        expect(chapterOf(_sparseToc, chapter), 2,
            reason: 'spine $chapter 属于一章');
      }
      expect(chapterOf(_sparseToc, 9), 6);
      expect(chapterOf(_sparseToc, 13), 10);
      expect(chapterOf(_sparseToc, 99), 14);
    });

    test('精确命中时与旧判据逐字同解', () {
      expect(chapterOf(_sparseToc, 0), 0);
      expect(chapterOf(_sparseToc, 2), 2);
      expect(chapterOf(_sparseToc, 14), 14);
    });

    test('当前位置在首条目录项之前 / 无位置：不标任何行', () {
      expect(
          chapterOf(
            const <TtuTocEntry>[TtuTocEntry(index: 3, label: '第一章')],
            1,
          ),
          isNull);
      expect(chapterOf(_sparseToc, null), isNull);
      expect(chapterOf(const <TtuTocEntry>[], 3), isNull);
    });

    test('标题行（index < 0）不参与判定', () {
      const List<TtuTocEntry> toc = <TtuTocEntry>[
        TtuTocEntry(index: -1, label: '本巻'),
        TtuTocEntry(index: 4, label: '第一章'),
      ];
      expect(chapterOf(toc, 2), isNull);
      expect(chapterOf(toc, 5), 4);
    });

    test('目录项顺序错乱时取的是最大不晚于当前的 index，不是列表最后一条', () {
      const List<TtuTocEntry> toc = <TtuTocEntry>[
        TtuTocEntry(index: 8, label: '後日談'),
        TtuTocEntry(index: 2, label: '第一章'),
      ];
      expect(chapterOf(toc, 5), 2);
    });

    test('同一 spine 章的多条锚点目录项、位置未知时命中章首那条', () {
      const List<TtuTocEntry> toc = <TtuTocEntry>[
        TtuTocEntry(index: 0, label: '巻頭'),
        TtuTocEntry(index: 0, label: '第一節', fragment: 'sec1'),
        TtuTocEntry(index: 0, label: '第二節', fragment: 'sec2'),
        TtuTocEntry(index: 1, label: '第二巻'),
      ];
      expect(resolveCurrentTocEntry(toc, 0, null), 0);
    });
  });

  testWidgets('章内非目录 spine 位置上，当前章那一行仍带勾', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final AppModel model = _testAppModel(db);
    final ReaderSettings? previousSettings = ReaderFushiSource.readerSettings;
    ReaderFushiSource.readerSettings = ReaderSettings(db)
      ..applyPrefsSnapshot(const <String, String>{});
    addTearDown(() {
      ReaderFushiSource.readerSettings = previousSettings;
    });

    // 读在 spine 4：「一章」（index 2）名下第三个 xhtml，没有任何目录项指向它。
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  ReaderQuickSettingsSheet(
                controller: null,
                toc: _sparseToc,
                readerProgress: const (4, 15),
                onJumpSection: (_, __) async {},
                onExitReader: () {},
                webViewController: _FakeInAppWebViewController(),
                appModel: model,
                ref: ref,
                isFushiReader: true,
                presentation:
                    ReaderQuickSettingsPresentation.sideSheetNavigation,
                onStyleChanged: () async {},
                onThemeChanged: () async {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check), findsOneWidget,
        reason: '修复前一行都没有勾 = 用户报的「没显示当前章节」');
    final Finder currentRow = find.ancestor(
      of: find.text('一章'),
      matching: find.byType(AdaptiveSettingsRow),
    );
    expect(
      find.descendant(of: currentRow, matching: find.byIcon(Icons.check)),
      findsOneWidget,
      reason: '勾必须落在当前章那一行，而不是别的章',
    );
  });
}
