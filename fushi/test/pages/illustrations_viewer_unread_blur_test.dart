import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/illustrations_viewer_page.dart';
import 'package:fushi_audio/fushi_audio.dart' show ReaderPositionRepository;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:fushi_engine/epub/epub_book.dart' show EpubImageRef;

/// 书架端「查看插图」= 阅读器内的同一份插图册（BUG-2589）。这里验的是书架端
/// 特有的装载与接线：真实解压目录 + 真实 Drift 库，「还没读到的插图先遮罩」
/// 按 `reader_positions` 判、没有位置行的书不按进度遮、揭开落库、跳转回调。
///
/// 判据与全局「图片模糊（防剧透）」开关无关：这里全程不设该开关（`readerSettings`
/// 为 null ⇒ 关），仍要求未读到的图被遮住。
void main() {
  // 1x1 透明 PNG（`Image.file` 能解码）。
  final Uint8List onePxPng = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
    0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, //
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
    0x42, 0x60, 0x82,
  ]);

  const String bookUid = 'test-book';

  late Directory extractDir;
  late FushiDatabase db;
  final List<Directory> tempDirs = <Directory>[];

  void writeText(String path, String content) {
    final File file = File('${extractDir.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    extractDir = Directory.systemTemp.createTempSync('hibiki_illust_unread');
    tempDirs.add(extractDir);

    writeText('META-INF/container.xml', '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');
    writeText('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Test Book</dc:title>
  </metadata>
  <manifest>
    <item id="cover" href="images/a_cover.png" media-type="image/png" properties="cover-image"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>
''');
    // 第 1 章有插图 b_head，第 2 章有插图 c_late；封面 a_cover 恒算已读到。
    writeText('OEBPS/text/ch1.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <p><img src="../images/b_head.png" alt=""/></p>
  <p>あいうえおかきくけこ</p>
</body></html>
''');
    writeText('OEBPS/text/ch2.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <p><img src="../images/c_late.png" alt=""/></p>
  <p>さしすせそたちつてと</p>
</body></html>
''');
    for (final String name in <String>[
      'a_cover.png',
      'b_head.png',
      'c_late.png',
    ]) {
      final File file = File('${extractDir.path}/OEBPS/images/$name');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(onePxPng);
    }
  });

  tearDown(() async {
    await db.close();
  });

  tearDownAll(() {
    for (final Directory dir in tempDirs) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录由 OS 回收（Windows 下解码句柄可能仍占用）。
      }
    }
  });

  final List<EpubImageRef> jumped = <EpubImageRef>[];

  /// 画廊页从一个空壳首页 push 出去（与书架一致），「跳转」要能真 pop 回来。
  Widget buildApp() {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => IllustrationsViewerPage(
                    bookTitle: 'Book',
                    extractDir: extractDir.path,
                    bookUid: bookUid,
                    database: db,
                    onJumpTo: (EpubImageRef ref) async => jumped.add(ref),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  /// 开页并等结构解析（isolate）+ Drift 读 + 宽高比探测都落定（真实 IO /
  /// isolate，必须在 [WidgetTester.runAsync] 内推进）。
  Future<void> openGallery(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await tester.pumpWidget(buildApp());
      await tester.tap(find.text('open'));
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(find.byKey(const ValueKey<String>('fushi_gallery_count')),
        findsOneWidget,
        reason: '装载完成后应渲染阅读器内的同一份插图册');
  }

  /// 锁着的卡 = 盖在真缩略图上的高斯模糊层（maskedIllustrationCover）。
  Finder maskedCards() => find.byType(ImageFiltered);
  Finder card(String src) =>
      find.byKey(ValueKey<String>('fushi_gallery_card_$src'));

  testWidgets('blurs illustrations past the reading position, cover excluded', (
    WidgetTester tester,
  ) async {
    await ReaderPositionRepository(
      db,
    ).save(bookUid: bookUid, sectionIndex: 0, normCharOffset: 0);

    await openGallery(tester);

    // 读到第 1 章章首：封面与章首插图已读到，第 2 章那张还没读到 → 只遮它。
    expect(maskedCards(), findsOneWidget);
    expect(
      find.descendant(
        of: card('OEBPS/images/c_late.png'),
        matching: find.byType(ImageFiltered),
      ),
      findsOneWidget,
    );
    expect(find.text('Unlocked 2 / 3'), findsOneWidget);
    // 有阅读位置 → 定位按钮与「当前阅读位置」标记都在。
    expect(find.byKey(const ValueKey<String>('fushi_gallery_position')),
        findsOneWidget);
    expect(find.text('Current reading position'), findsOneWidget);
  });

  testWidgets('reading to the end leaves nothing blurred', (
    WidgetTester tester,
  ) async {
    await ReaderPositionRepository(
      db,
    ).save(bookUid: bookUid, sectionIndex: 1, normCharOffset: 10000);

    await openGallery(tester);

    expect(maskedCards(), findsNothing);
    expect(find.text('Unlocked 3 / 3'), findsOneWidget);
  });

  testWidgets(
      'a book never opened is not blurred by progress and has no locate',
      (WidgetTester tester) async {
    // 没有 reader_positions 行：不能退化成 (0, 0) 把开篇之后全糊掉。
    await openGallery(tester);

    expect(maskedCards(), findsNothing);
    expect(find.text('Unlocked 3 / 3'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('fushi_gallery_position')),
        findsNothing);
    expect(find.text('Current reading position'), findsNothing);
  });

  testWidgets('revealing a blurred illustration persists to revealed_images', (
    WidgetTester tester,
  ) async {
    await ReaderPositionRepository(
      db,
    ).save(bookUid: bookUid, sectionIndex: 0, normCharOffset: 0);

    await openGallery(tester);
    expect(maskedCards(), findsOneWidget);

    // 点锁着的卡 → 弹窗「仍要查看」→ 揭开。
    await tester.tap(card('OEBPS/images/c_late.png'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_gallery_locked_reveal')),
    );
    await tester.runAsync(() async {
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();

    // 揭开：遮罩消失，且写进共享真相源（阅读器下次开书据此不再遮）。
    expect(maskedCards(), findsNothing);
    expect(await db.getRevealedImageKeys(bookUid), <String>{
      'OEBPS/images/c_late.png',
    });
  });

  testWidgets('jump menu pops the page and hands the illustration to onJumpTo',
      (WidgetTester tester) async {
    jumped.clear();
    await openGallery(tester);

    await tester.longPress(card('OEBPS/images/b_head.png'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi_gallery_menu_jump')),
    );
    await tester.pumpAndSettle();

    expect(jumped.map((EpubImageRef r) => r.src), <String>[
      'OEBPS/images/b_head.png',
    ]);
    expect(jumped.single.jumpChapterIndex, 0);
    expect(find.byType(IllustrationsViewerPage), findsNothing,
        reason: '跳转前画廊页必须先 pop，让调用方开的阅读器落在栈顶');
  });
}
