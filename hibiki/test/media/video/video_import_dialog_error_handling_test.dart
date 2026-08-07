import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1117 守卫：VideoImportDialog 四个导入方法（_doImport / _importStreamUrl /
/// _importPlaylistFromPath / _pickFolder）此前是 `try{}finally{}` 无 catch，
/// 导入异常逃逸 async zone（三处调用点还是 fire-and-forget），用户只见 spinner
/// 停住、无任何提示。修复后异常必须被捕获：ErrorLogService 落日志 + toast 提示，
/// `importing` 在 finally 复位——该模式现已结构化为 `ImportFlowMixin.runImport`
/// 模板（审计 §1-K），四个方法全部改走模板，行为不变。
///
/// 两层守卫：
/// 1) **widget 行为层**：注入 `listAll()` 必抛的仓库（四条导入路径都先经
///    `_uniqueBookUid → repo.listAll()`，在进 ffmpeg 前确定性触发 catch），断言
///    异常不再逃逸 zone（`takeException() == null`，修复前此断言红）且 `importing`
///    已复位（确认按钮恢复可用、spinner 消失）。
/// 2) **源码扫描层**：对 4 个方法各断言以对应 logTag 走 `runImport(` 模板，
///    覆盖 widget 测试驱动不到的 `_importPlaylistFromPath` / `_pickFolder`
///    （依赖 FilePicker / 目录选择器静态入口，无法在 widget 测试注入）；模板
///    体内的 catch/log/toast 契约由 import_flow_mixin_test.dart 守卫。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  group('import errors are caught, logged, and _busy is reset', () {
    testWidgets('stream url import failure does not escape the zone',
        (WidgetTester tester) async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = _ThrowingRepo(db);
      final int entriesBefore = ErrorLogService.instance.entries.length;

      await tester.pumpWidget(buildApp(VideoImportDialog(repo: repo)));

      // 第一个 TextField 是流 URL 输入框；可播 URL 使确认按钮可用并短路到
      // _importStreamUrl。
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.com/v.mp4',
      );
      await tester.pump();

      final Finder confirm =
          find.widgetWithText(FilledButton, t.video_import_confirm);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      // 修复核心：异常被 catch，不再逃逸 async zone（修复前此断言红）。
      expect(tester.takeException(), isNull);
      // 落进错误日志（用户可在错误日志页看到，而非完全静默）。
      expect(
        ErrorLogService.instance.entries.skip(entriesBefore).any(
            (ErrorLogEntry e) => e.source == 'VideoImportDialog.importStream'),
        isTrue,
      );
      // finally 复位 _busy：确认按钮恢复可用、spinner 消失（不再卡住）。
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'fire-and-forget auto import (initialStreamUrl) failure is caught',
        (WidgetTester tester) async {
      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final VideoBookRepository repo = _ThrowingRepo(db);
      final int entriesBefore = ErrorLogService.instance.entries.length;

      // 拖入 URL 的 postFrameCallback 自动导入是 fire-and-forget：无 catch 时
      // 异常必然无人接、直接逃逸 zone。
      await tester.pumpWidget(buildApp(VideoImportDialog(
        repo: repo,
        initialStreamUrl: 'https://example.com/auto.mp4',
      )));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        ErrorLogService.instance.entries.skip(entriesBefore).any(
            (ErrorLogEntry e) => e.source == 'VideoImportDialog.importStream'),
        isTrue,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('source guard: all four import methods route through runImport', () {
    late String source;

    setUpAll(() {
      // 测试 cwd 是 hibiki/；源码相对路径稳定（范式同 video_import_dialog_busy_guard_test）。
      source = File('lib/src/media/video/video_import_dialog.dart')
          .readAsStringSync();
    });

    // _importPlaylistFromPath / _pickFolder 依赖 FilePicker / 目录选择器静态入口，
    // widget 测试驱动不到，靠源码扫描锁住「以对应 logTag 走 runImport 模板」。
    for (final String tag in const <String>[
      'VideoImportDialog.import', // _doImport
      'VideoImportDialog.importStream', // _importStreamUrl
      'VideoImportDialog.importPlaylist', // _importPlaylistFromPath
      'VideoImportDialog.pickFolder', // _pickFolder
    ]) {
      test('import method routes through runImport with tag $tag', () {
        // dart format 可能折行，故用允许空白的正则而非裸 contains。
        expect(
          RegExp("logTag:\\s*'${RegExp.escape(tag)}',").hasMatch(source),
          isTrue,
          reason: '导入方法必须以 logTag $tag 走 ImportFlowMixin.runImport 模板'
              '（模板保证 catch 落日志 + toast + importing 复位），'
              '否则导入异常回到静默逃逸（BUG-1117 回归）',
        );
      });
    }

    test('no handwritten try/finally or direct ErrorLogService call remains',
        () {
      // 四方法收敛到 runImport 后，本文件不应再出现手写 finally 或直接
      // ErrorLogService 调用——防止未来新增导入方法复制旧的 try{}finally{}
      // 形态（无 catch，异常静默逃逸 async zone）回归。
      expect(
        source.contains('} finally {'),
        isFalse,
        reason: '新增导入方法必须走 ImportFlowMixin.runImport 模板，'
            '不要手写 try/finally（BUG-1117 回归风险）',
      );
      expect(
        source.contains('ErrorLogService.instance.log('),
        isFalse,
        reason: '导入错误日志统一由 runImport 模板落，不在本文件手写',
      );
      // 模板体内 catch 在 finally 之前、且落日志 + toast——锁在 mixin 源码上。
      final String mixinSource =
          File('lib/src/media/import/import_flow_mixin.dart')
              .readAsStringSync();
      expect(
        mixinSource.indexOf('} catch (e, stack) {'),
        allOf(isNonNegative, lessThan(mixinSource.indexOf('} finally {'))),
        reason: 'runImport 模板必须 catch 后 finally（catch 落日志/提示、'
            'finally 复位 importing）',
      );
    });
  });
}

/// 四条导入路径都先经 `_uniqueBookUid → repo.listAll()` 再进 ffmpeg——override
/// listAll 抛错即可在进外部进程前确定性触发 catch 路径。
class _ThrowingRepo extends VideoBookRepository {
  const _ThrowingRepo(super.db);

  @override
  Future<List<VideoBookRow>> listAll() async => throw StateError('boom');
}
