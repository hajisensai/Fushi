import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

// BUG-446 守卫：添加本地音频数据库失败时，不再用裸 `catch (_)` 吞掉真因，
// 而是把完整异常记进 ErrorLogService、把异常摘要带进可见反馈；并修掉
// importFile 的「源文件不存在静默跳过 copy」假成功。源码扫描守卫，防回归。
void main() {
  final String dialog = File(
    'lib/src/pages/implementations/dictionary_settings_dialog_page.dart',
  ).readAsStringSync();
  final String schema = File(
    'lib/src/settings/settings_schema_lookup.dart',
  ).readAsStringSync();
  final String manager = File(
    'lib/src/models/local_audio_manager.dart',
  ).readAsStringSync();

  group('BUG-446 add-audio-db error is no longer swallowed', () {
    test('dialog _addLocalDb catches with binding and logs the error', () {
      // 旧路径：`} catch (_) {` 弹通用文案、丢异常对象。修复后带 (e, st)、
      // 记 ErrorLogService、用带 reason 的文案。
      expect(
          dialog.contains(
              'if (mounted) _showSnack(t.local_audio_import_failed);'),
          isFalse,
          reason: '裸 catch(_) 吞掉添加音频库异常的旧路径必须移除');
      expect(dialog, contains('catch (e, st)'));
      expect(
          dialog,
          contains(
              "ErrorLogService.instance.log('AudioSourcesDialog.addLocalDb'"));
      expect(dialog, contains('t.local_audio_import_failed_detail(reason:'));
    });

    test('file picker logs unexpected selection and fails on null path', () {
      // 不再用会抛 StateError 的 `files.single`；改记文件数 + 区分 path 为空。
      expect(schema.contains('result?.files.single.path'), isFalse,
          reason: 'files.single 会在 0/多文件时抛 StateError 被吞，必须移除');
      expect(schema, contains("'AudioSourcesDialog.pickLocalDb'"));
      expect(schema, contains(r'count=${result.files.length}'));
      expect(schema, contains('throw Exception('));
    });

    test(
        'importFile no longer silently skips a missing source (no false '
        'success)', () {
      // 旧：源文件不存在则跳过 copy、返回空 path entry。修复后改为显式抛错。
      expect(manager, contains('if (!await sourceFile.exists())'));
      expect(manager, contains('throw FileSystemException('));
    });
  });
}
