import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/audiobook/book_import_dialog.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 守卫 TODO-790-B：三个导入对话框（book/audiobook/video）的 build 必须把根
/// frame 包进 [HibikiFileDropTarget]，否则拖文件进打开的模态对话框会被页级
/// drop target 因 `isCurrent` 守卫静默忽略。
///
/// 源码扫描守卫（仿 drag_drop_platform_guard_test.dart）：断言三文件各引用
/// `HibikiFileDropTarget` 且各自定义 `_handleDialogDrop`。
void main() {
  const Map<String, String> dialogs = <String, String>{
    'book': 'lib/src/media/audiobook/book_import_dialog.dart',
    'audiobook': 'lib/src/media/audiobook/audiobook_import_dialog.dart',
    'video': 'lib/src/media/video/video_import_dialog.dart',
  };

  dialogs.forEach((String name, String path) {
    test('$name import dialog wraps its frame in HibikiFileDropTarget', () {
      final String src = File(path).readAsStringSync();
      expect(src.contains('HibikiFileDropTarget('), isTrue,
          reason: '$name dialog must accept drops onto the modal route');
      expect(src.contains('_handleDialogDrop'), isTrue,
          reason: '$name dialog must route drops into its fields');
    });
  });

  // A 守卫：BookImportDialog 收到 initialAudioPaths 后把音频填进表单。
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets('BookImportDialog prefills dragged audio into the audio row',
      (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      buildApp(
        BookImportDialog(
          repo: SrtBookRepository(db),
          audiobookRepo: AudiobookRepository(db),
          db: db,
          initialEpubPath: r'C:\b\My Novel.epub',
          initialAudioPaths: const <String>[r'C:\b\My Novel.mp3'],
        ),
      ),
    );
    await tester.pump();

    // 单个音频时音频行 subtitle 展示其 basename。
    expect(find.textContaining('My Novel.mp3'), findsWidgets);
  });
}
