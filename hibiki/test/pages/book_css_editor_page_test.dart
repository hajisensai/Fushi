import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:hibiki/src/pages/implementations/book_css_editor_page.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart'
    show kHibikiSettingsDialogMaxWidth;

// Minimal Slang stub — the real strings.g.dart pulls in too many
// dependencies for a focused widget test.  We wrap the page in a
// MaterialApp whose Localizations delegate is the generated one, but
// if that causes import issues the tests can be run with
// `flutter test --dart-define=SLANG_MOCK=true` and a conditional
// import.  For now we import the real generated file:
import 'package:hibiki/i18n/strings.g.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    tmpDir = Directory.systemTemp.createTempSync('css_editor_test_');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Widget buildApp(String extractDir) {
    return TranslationProvider(
      child: MaterialApp(
        home: BookCssEditorPage(extractDir: extractDir),
      ),
    );
  }

  // BUG-040: the editor loads CSS off the UI thread via async `dart:io`. Real
  // file IO only advances under `runAsync`, but the `await` continuations in
  // `_reload` are bound to the test's fake-async zone and only run on `pump()`.
  // Alternating the two drains the discover→read chain; we stop once the
  // loading `CircularProgressIndicator` clears (pumpAndSettle can't be used —
  // it spins forever on the spinner's indefinite animation).
  Future<void> settleAsyncLoad(WidgetTester tester) async {
    for (int i = 0; i < 50; i++) {
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> pumpEditor(WidgetTester tester, String extractDir) async {
    await tester.pumpWidget(buildApp(extractDir));
    await settleAsyncLoad(tester);
  }

  void createCss(Directory root, String rel, String content) {
    final File f = File(p.join(root.path, rel.replaceAll('/', p.separator)));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  // TODO-1234: book CSS discovery no longer walks the extract dir for *.css —
  // it reads the OPF manifest (META-INF/container.xml -> content.opf -> items
  // with media-type="text/css"). Seed a minimal EPUB package at the extract-dir
  // root so `BookCssRepository.discoverCssFiles` finds the stylesheets written
  // via createCss. The OPF sits at the root, so manifest hrefs equal the
  // extract-dir-relative paths passed in [cssRelPaths].
  void seedEpubManifest(Directory root, List<String> cssRelPaths) {
    final StringBuffer items = StringBuffer();
    for (int i = 0; i < cssRelPaths.length; i++) {
      items.write(
        '<item id="css$i" href="${cssRelPaths[i]}" media-type="text/css"/>',
      );
    }
    createCss(
      root,
      'META-INF/container.xml',
      '<?xml version="1.0"?>'
          '<container version="1.0" '
          'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
          '<rootfiles>'
          '<rootfile full-path="content.opf" '
          'media-type="application/oebps-package+xml"/>'
          '</rootfiles>'
          '</container>',
    );
    createCss(
      root,
      'content.opf',
      '<?xml version="1.0"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0">'
          '<manifest>'
          '$items'
          '</manifest>'
          '<spine/>'
          '</package>',
    );
  }

  testWidgets(
    'BUG-040: opens off the UI thread — loading first frame, content after load',
    (WidgetTester tester) async {
      createCss(tmpDir, 'a.css', 'aaa');
      createCss(tmpDir, 'b.css', 'bbb');
      seedEpubManifest(tmpDir, ['a.css', 'b.css']);

      await tester.pumpWidget(buildApp(tmpDir.path));
      // Only one frame — the discover-walk + reads are still in flight off the
      // UI thread, so the page must NOT have synchronously populated its tabs
      // (that synchronous populate is exactly the freeze we removed).
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('a.css'), findsNothing);

      // Drive the real async file IO until the loading spinner clears.
      await settleAsyncLoad(tester);

      // After the off-thread load resolves, tabs + editor content appear.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('a.css'), findsOneWidget);
      expect(find.text('b.css'), findsOneWidget);
      final TextField tf =
          tester.widget<TextField>(find.byType(TextField).first);
      expect(tf.controller!.text, 'aaa');
    },
  );

  testWidgets(
    'cancel tab switch keeps _selectedIndex on original tab',
    (WidgetTester tester) async {
      createCss(tmpDir, 'a.css', 'aaa');
      createCss(tmpDir, 'b.css', 'bbb');
      seedEpubManifest(tmpDir, ['a.css', 'b.css']);

      await pumpEditor(tester, tmpDir.path);

      // Verify two chips rendered, first selected
      expect(find.text('a.css'), findsOneWidget);
      expect(find.text('b.css'), findsOneWidget);

      // Type in the editor to create unsaved changes
      await tester.enterText(find.byType(TextField).first, 'modified');
      await tester.pumpAndSettle();

      // Tab label should now show *
      expect(find.text('* a.css'), findsOneWidget);

      // Tap the second chip to trigger guard dialog
      await tester.tap(find.text('b.css'));
      await tester.pumpAndSettle();

      // Dialog should appear
      expect(find.text(t.book_css_editor_unsaved_changes), findsOneWidget);

      // Tap Cancel
      await tester.tap(find.text(t.book_css_editor_cancel));
      await tester.pumpAndSettle();

      // First chip should still be selected (editor still shows modified text)
      final TextField tf =
          tester.widget<TextField>(find.byType(TextField).first);
      expect(tf.controller!.text, 'modified');
    },
  );

  testWidgets(
    'unsaved changes dialog fits a compact desktop window',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 240);
      addTearDown(tester.view.reset);

      createCss(tmpDir, 'a.css', 'aaa');
      createCss(tmpDir, 'b.css', 'bbb');
      seedEpubManifest(tmpDir, ['a.css', 'b.css']);

      await pumpEditor(tester, tmpDir.path);

      await tester.enterText(find.byType(TextField).first, 'modified');
      await tester.pumpAndSettle();

      await tester.tap(find.text('b.css'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(t.book_css_editor_unsaved_changes), findsOneWidget);
    },
  );

  testWidgets(
    'reset current discards editor changes when no .original exists',
    (WidgetTester tester) async {
      createCss(tmpDir, 'style.css', 'original content');
      seedEpubManifest(tmpDir, ['style.css']);

      await pumpEditor(tester, tmpDir.path);

      // Type to create unsaved changes
      await tester.enterText(find.byType(TextField).first, 'user edits');
      await tester.pumpAndSettle();

      // Reset Current should be enabled (unsaved editor changes)
      final Finder resetBtn = find.text(t.book_css_editor_reset_current);
      expect(resetBtn, findsOneWidget);
      await tester.tap(resetBtn);
      await tester.pumpAndSettle();

      // Confirm dialog
      expect(find.text(t.book_css_editor_confirm_reset), findsOneWidget);
      await tester.tap(find.text(t.book_css_editor_reset_current).last);
      await tester.pumpAndSettle();

      // Editor should be back to disk content
      final TextField tf =
          tester.widget<TextField>(find.byType(TextField).first);
      expect(tf.controller!.text, 'original content');

      // No .original file should exist on disk
      expect(
          File('${tmpDir.path}${p.separator}style.css.original').existsSync(),
          isFalse);
    },
  );

  testWidgets(
    'TODO-1142: body + bottom actions width-capped to shared settings dialog '
    'width so the full-screen editor matches sibling dialog pages',
    (WidgetTester tester) async {
      // BookCssEditorPage 是逃出 900px 限宽设置弹窗的全屏 push 路由；桌面下若不约束
      // 正文宽度会铺满整屏，与限宽弹窗里的兄弟设置页不一致。修复把 body 与底部动作栏
      // 包进 Center + ConstrainedBox(maxWidth: kHibikiSettingsDialogMaxWidth)。
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1920, 1080);
      addTearDown(tester.view.reset);

      createCss(tmpDir, 'a.css', 'aaa');
      seedEpubManifest(tmpDir, ['a.css']);

      await pumpEditor(tester, tmpDir.path);

      // 找出所有约束到共享设置弹窗宽度的 ConstrainedBox（正文 + 底部动作栏各一个）。
      final Iterable<ConstrainedBox> capped = tester
          .widgetList<ConstrainedBox>(find.byType(ConstrainedBox))
          .where((ConstrainedBox b) =>
              b.constraints.maxWidth == kHibikiSettingsDialogMaxWidth);
      expect(capped.length, greaterThanOrEqualTo(2),
          reason: '正文与底部动作栏都应被约束到 kHibikiSettingsDialogMaxWidth');

      // 编辑器正文仍正常渲染（TextField expands:true 需要有界高度，包裹层用
      // SizedBox(height: infinity) 保留满高，不应抛布局异常）。
      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsWidgets);
    },
  );
}
