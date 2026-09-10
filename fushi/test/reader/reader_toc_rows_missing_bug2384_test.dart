import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// BUG-2384：阅读器目录「章节列表显示不全」的两条根因。
///
///  1. 当前章那一行的 `GlobalKey` 挂到了**每一条** index 命中当前章的目录项上。
///     同一 spine 章有多条目录项（一个 xhtml 装整卷、目录靠锚点分节）是常态，
///     于是 release 下 `Element._retakeInactiveElement` 把 element 从前一行手里
///     抢走 —— 目录里真的少一行。
///  2. 解析期：`<a>` 里只有 `<img>` 的图片目录项 innerText 为空，旧代码把这条
///     `<li>` **连同已解析好的整棵子树**一起丢掉，一个无名分组节点就能让它名下
///     所有章节从目录里消失。
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

void main() {
  testWidgets('every toc row of the current chapter stays on screen',
      (WidgetTester tester) async {
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

    // 三条目录项全指向 spine 章 0（当前章），只有锚点不同 —— 修复前它们会共用
    // 同一个 GlobalKey。
    const List<TtuTocEntry> toc = <TtuTocEntry>[
      TtuTocEntry(index: 0, label: '巻頭'),
      TtuTocEntry(index: 0, label: '第一節', fragment: 'sec1'),
      TtuTocEntry(index: 0, label: '第二節', fragment: 'sec2'),
      TtuTocEntry(index: 1, label: '第二巻'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) =>
                  ReaderQuickSettingsSheet(
                controller: null,
                toc: toc,
                readerProgress: const (0, 2),
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

    for (final String label in <String>['巻頭', '第一節', '第二節', '第二巻']) {
      expect(find.text(label), findsOneWidget, reason: '目录少行 = 用户报的「显示不全」');
    }
  });

  group('EpubParser nav parsing keeps every entry it can name', () {
    late Directory extractDir;

    setUp(() {
      extractDir = Directory.systemTemp.createTempSync('epub_toc_rows_test_');
    });

    tearDown(() {
      if (extractDir.existsSync()) {
        extractDir.deleteSync(recursive: true);
      }
    });

    test(
        'image-only toc entry is named by alt; an unnamed group keeps its '
        'children', () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXml),
        _textFile('OEBPS/content.opf', _opf),
        _textFile('OEBPS/nav.xhtml', _navXhtml),
        _textFile('OEBPS/chapter-1.xhtml', _chapterXhtml('One.')),
        _textFile('OEBPS/chapter-2.xhtml', _chapterXhtml('Two.')),
        _textFile('OEBPS/chapter-3.xhtml', _chapterXhtml('Three.')),
      ]);

      final EpubBook book = EpubParser.parseSync(bytes, extractDir.path);
      final List<String> labels =
          book.toc.map((EpubTocItem e) => e.label).toList();

      expect(labels, contains('口絵'), reason: '图片目录项要用 img 的 alt 命名，而不是整条丢掉');
      // 无名分组节点（<li> 只有一个 <ol>，没有 <a>/<span>）：它自己无从显示，
      // 但名下的章节必须并入上一层，不能跟着消失。
      final List<String> flatLabels = <String>[
        for (final EpubTocItem top in book.toc) ...<String>[
          top.label,
          ...top.children.map((EpubTocItem c) => c.label),
        ],
      ];
      expect(flatLabels, contains('第二章'), reason: '一个无名分组节点不得把名下整段章节从目录里抹掉');
    });
  });
}

Uint8List _encodeArchive(List<ArchiveFile> files) {
  final Archive archive = Archive();
  for (final ArchiveFile file in files) {
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

const String _containerXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const String _opf = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Toc Rows Book</dc:title>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="chapter-1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="chapter-2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch3" href="chapter-3.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
    <itemref idref="ch3"/>
  </spine>
</package>
''';

// 第一条：图片目录项（<a> 内只有 <img>，无文本）。
// 第二条：无名分组 <li>（只有 <ol>，没有 <a>/<span>），名下挂着「第二章」。
const String _navXhtml = '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Table of Contents</title></head>
  <body>
    <nav epub:type="toc">
      <ol>
        <li><a href="chapter-1.xhtml"><img src="cover.jpg" alt="口絵"/></a></li>
        <li>
          <ol>
            <li><a href="chapter-2.xhtml">第二章</a></li>
          </ol>
        </li>
        <li><a href="chapter-3.xhtml">第三章</a></li>
      </ol>
    </nav>
  </body>
</html>
''';

String _chapterXhtml(String body) => '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter</title></head>
  <body><p>$body</p></body>
</html>
''';
