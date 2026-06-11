import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/dictionary_import_manager.dart';
import 'package:path/path.dart' as path;

/// TODO-082 守卫：词典导入不堵塞 UI（目录打包移到后台 isolate）、失败写
/// [ErrorLogService]、开始/成功/失败都给用户提示。
///
/// - 行为测试：`packDirectoryToZip` 是纯路径输入/纯文件输出的打包函数，可在 host
///   上真跑（无需 native FFI），验证「移到后台 isolate 后打包结果与原同步实现
///   一致」——这是「不破坏现有导入正确性」的硬证据。
/// - 源码守卫：锁定后台化 / 错误日志 / 用户提示三条契约，撤掉任一即转红。
void main() {
  group('TODO-082 behaviour: packDirectoryToZip 正确打包目录', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('hibiki_pack_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('递归收集所有文件并保留相对路径与字节内容', () {
      final Directory src = Directory(path.join(tmp.path, 'dict'))
        ..createSync(recursive: true);
      File(path.join(src.path, 'index.json'))
          .writeAsStringSync('{"title":"テスト辞典"}');
      final Directory sub = Directory(path.join(src.path, 'sub'))
        ..createSync(recursive: true);
      File(path.join(sub.path, 'term_bank_1.json'))
          .writeAsStringSync('[["語","",""]]');
      final List<int> binary = List<int>.generate(2048, (int i) => i % 256);
      File(path.join(sub.path, 'blob.bin')).writeAsBytesSync(binary);

      final String zipPath = path.join(tmp.path, 'out.zip');
      DictionaryImportManager.packDirectoryToZip(src.path, zipPath);

      expect(File(zipPath).existsSync(), isTrue);

      final Archive archive =
          ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      final Map<String, List<int>> byName = <String, List<int>>{
        for (final ArchiveFile f in archive)
          if (f.isFile) f.name.replaceAll(r'\', '/'): f.content as List<int>,
      };

      expect(byName.keys.toSet(), <String>{
        'index.json',
        'sub/term_bank_1.json',
        'sub/blob.bin',
      });
      expect(utf8.decode(byName['index.json']!), '{"title":"テスト辞典"}');
      expect(byName['sub/blob.bin'], binary);
    });

    test('空目录打包成有效空 zip（不抛异常）', () {
      final Directory src = Directory(path.join(tmp.path, 'empty'))
        ..createSync(recursive: true);
      final String zipPath = path.join(tmp.path, 'empty.zip');
      DictionaryImportManager.packDirectoryToZip(src.path, zipPath);
      expect(File(zipPath).existsSync(), isTrue);
      final Archive archive =
          ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      expect(archive.where((ArchiveFile f) => f.isFile).isEmpty, isTrue);
    });
  });

  group('TODO-082 source guards', () {
    final String manager = File('lib/src/models/dictionary_import_manager.dart')
        .readAsStringSync();
    final String dialog =
        File('lib/src/pages/implementations/dictionary_dialog_page.dart')
            .readAsStringSync();

    test('目录导入把打包移到后台 isolate（不在主 isolate 同步压缩）', () {
      // 真正会卡 UI 的同步重活：listSync(recursive) + readAsBytesSync +
      // ZipEncoder().encode，必须只存在于丢进 Isolate.run 的 packDirectoryToZip
      // 里，不能再裸跑在 importFromDirectory 主体。
      expect(manager.contains('Isolate.run'), isTrue,
          reason: '目录打包必须在后台 isolate 执行');
      expect(manager.contains('packDirectoryToZip'), isTrue);
      expect(manager.contains('Isolate.run(() => packDirectoryToZip'), isTrue,
          reason: '打包函数必须经 Isolate.run 调用');

      // ZipEncoder().encode 只能出现一次，且在 packDirectoryToZip 里。
      final int encodeCount = 'ZipEncoder().encode'.allMatches(manager).length;
      expect(encodeCount, 1, reason: '同步压缩只应剩 packDirectoryToZip 内一处');
    });

    test('packDirectoryToZip 暴露给测试且为纯静态函数', () {
      expect(manager.contains('@visibleForTesting'), isTrue);
      expect(manager.contains('static void packDirectoryToZip('), isTrue);
    });

    test('导入失败写入 ErrorLogService（不吞异常）', () {
      expect(manager.contains("ErrorLogService.instance.log('DictImport(dir)'"),
          isTrue,
          reason: '目录导入失败必须落错误日志');
      expect(
          manager.contains("ErrorLogService.instance.log('DictImport(file)'"),
          isTrue,
          reason: '文件导入失败必须落错误日志');
      expect(
          dialog.contains(
              "ErrorLogService.instance.log('DictionaryDialog.folderImport'"),
          isTrue);
      expect(
          dialog.contains(
              "ErrorLogService.instance.log('DictionaryDialog.fileImport'"),
          isTrue);
    });

    test('开始导入给用户提示（两 UI 入口）', () {
      final int startToasts = 't.dict_import_started'.allMatches(dialog).length;
      expect(startToasts, greaterThanOrEqualTo(2),
          reason: '多文件导入与目录导入入口都要在开始时提示');
    });

    test('成功导入给用户提示（数量汇总）', () {
      expect(dialog.contains('t.dict_import_success_summary'), isTrue,
          reason: '多文件路径成功后给成功提示');
      expect(manager.contains('t.dict_import_success_summary'), isTrue,
          reason: '目录/批量路径成功后给成功提示');
    });

    test('失败仍给用户提示（汇总文案保留）', () {
      expect(manager.contains('formatImportFailureSummary'), isTrue);
      expect(dialog.contains('formatImportFailureSummary'), isTrue);
    });
  });
}
