import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/illustrations_viewer_page.dart';
import 'package:fushi_audio/fushi_audio.dart' show ReaderPositionRepository;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;

/// 图片库「还没读到的插图先遮罩」——防的是从书架点进插画页被后文剧透。
///
/// 判据是阅读位置（`ReaderPosition`）与插图在书中的位置（`IllustrationProgressIndex`），
/// **与全局「图片模糊（防剧透）」开关无关**：这里全程不设该开关（`readerSettings`
/// 为 null ⇒ 关），仍要求未读到的图被遮住。widget 行为测试：真实解压目录 + 真实
/// Drift 库，断言渲染出的遮罩数量、点击揭开、以及揭开落库。
void main() {
  // 1x1 透明 PNG（`Image.memory` 能解码）。
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

  Widget buildApp() {
    return TranslationProvider(
      child: MaterialApp(
        home: IllustrationsViewerPage(
          bookTitle: 'Book',
          extractDir: extractDir.path,
          bookUid: bookUid,
          database: db,
        ),
      ),
    );
  }

  /// 开页并等三张图 + 后台 isolate 建好的进度索引都落定（真实 IO / isolate，
  /// 必须在 [WidgetTester.runAsync] 内推进）。
  Future<void> openGrid(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(buildApp());
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
  }

  Finder blurCovers() => find.byIcon(Icons.visibility_off_outlined);

  testWidgets('blurs illustrations past the reading position, cover excluded', (
    WidgetTester tester,
  ) async {
    await ReaderPositionRepository(
      db,
    ).save(bookUid: bookUid, sectionIndex: 0, normCharOffset: 0);

    await openGrid(tester);

    // 读到第 1 章章首：封面与章首插图已读到，第 2 章那张还没读到 → 只遮它。
    expect(blurCovers(), findsOneWidget);
  });

  testWidgets('reading to the end leaves nothing blurred', (
    WidgetTester tester,
  ) async {
    await ReaderPositionRepository(
      db,
    ).save(bookUid: bookUid, sectionIndex: 1, normCharOffset: 10000);

    await openGrid(tester);

    expect(blurCovers(), findsNothing);
  });

  testWidgets('tapping a blurred illustration reveals it and persists', (
    WidgetTester tester,
  ) async {
    await ReaderPositionRepository(
      db,
    ).save(bookUid: bookUid, sectionIndex: 0, normCharOffset: 0);

    await openGrid(tester);
    expect(blurCovers(), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(blurCovers().first);
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });
    await tester.pump();

    // 揭开：遮罩消失，且写进共享真相源（阅读器下次开书据此不再遮）。
    expect(blurCovers(), findsNothing);
    expect(await db.getRevealedImageKeys(bookUid), <String>{
      'OEBPS/images/c_late.png',
    });
  });
}
