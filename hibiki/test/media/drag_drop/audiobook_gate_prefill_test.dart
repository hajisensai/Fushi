import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 锁死 `_initExisting` 的拖拽预填闸门（drag-drop-import 计划审查发现）。
///
/// 当 [AudiobookImportDialog] 收到非空 `initialAudioPaths`（或 `initialAlignmentPath`）
/// 时，即使本书**已有完整有声书**，对话框也必须渲染可保存的导入表单而非只读
/// 的 `_buildAttachedView`——否则拖入的音频/对齐文件会被只读视图静默丢弃。
///
/// 两态用 [AudiobookImportDialogFrame] 的标题区分：导入表单态 = `t.audiobook_import`，
/// 只读态 = `t.audiobook_attached`。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );
  }

  testWidgets(
    'prefill forces the import form even when the book already has audio',
    (WidgetTester tester) async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final AudiobookRepository repo = AudiobookRepository(db);

      // 造一本「已有完整有声书」的记录：audioPaths 非空 → _existingHasAudio 为真。
      // 无需真实文件，闸门判定只看记录字段。
      const String bookKey = 'gate-prefill-book';
      final Audiobook existing = Audiobook()
        ..bookKey = bookKey
        ..audioPaths = <String>['/persisted/$bookKey/a.mp3']
        ..alignmentFormat = 'srt'
        ..alignmentPath = '/persisted/$bookKey/align.srt';
      await repo.saveAudiobook(existing);

      // 自检：确实是已有完整有声书（否则测试不锁闸门，等同没断言）。
      final Audiobook? loaded = await repo.findByBookKey(bookKey);
      expect(loaded, isNotNull);
      expect(loaded!.audioPaths, isNotEmpty);

      await tester.pumpWidget(
        buildApp(
          AudiobookImportDialog(
            bookKey: bookKey,
            repo: repo,
            initialAudioPaths: const <String>['/x/a.mp3'],
          ),
        ),
      );
      // _initExisting 是 async（一次 DB 往返）：用显式 pump 排空 future 让
      // _existingLoaded 变 true。不能 pumpAndSettle——加载态的 spinner 是
      // 无限动画，永不 settle 会超时。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 渲染的是导入表单（title=audiobook_import），不是只读视图
      // （title=audiobook_attached）。
      expect(find.text(t.audiobook_import), findsOneWidget);
      expect(find.text(t.audiobook_attached), findsNothing);
    },
  );
}
