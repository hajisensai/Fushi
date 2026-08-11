// BUG-1574：书架「重新定位 SRT 音频」→ 在系统文件选择器里点「取消」→ app 崩。
//
// ```
// Unsupported operation: Cannot modify an unmodifiable list
// #0  UnmodifiableListMixin.sort (dart:_internal/list.dart:147)
// #1  _ReaderHistoryBooks._pickSrtAudioFiles (books.part.dart:1047)
// ```
//
// 根因不在书架，在 `pickRealFilePaths`：它有两条返回**编译期常量空列表**的路径
// （用户取消 → `result == null`；页面已销毁 → `!context.mounted`）。Dart 的常量列表
// 是 `UnmodifiableListMixin`，`sort` 无条件抛 `UnsupportedError`——**空列表照抛**，
// 不是「非空才抛」。而四个调用点（有声书导入 / 书导入 / 阅读器补音频 / 书架重新定位
// SRT 音频）全是「先就地 sort、再判空」，于是四个入口一起踩。
//
// 本文件两条腿：
// ① 行为测试：把 `FilePicker.platform` 换成假实现，真的走一遍两条空结果路径，
//    对返回值就地 `sort` + `add`。这条不靠正则，改坏了必红。
// ② 源码守卫：钉住「这个文件不产出任何 const 集合字面量」。行为测试只能覆盖今天
//    存在的返回路径，明天新加的分支要靠它兜。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/models/app_model.dart';

import '../../helpers/source_guard.dart';
import '../../helpers/test_platform_services.dart';

/// 假 file_picker：`result == null` 复现「用户点了取消」。
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker([this.result]);

  final FilePickerResult? result;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      result;
}

/// 复刻四个调用点的真实用法：**先就地 sort，再判空**。
/// 返回不可变列表时这里就是崩溃现场（books.part.dart 的 `paths.sort(...)`）。
void _sortLikeCallSitesDo(List<String> paths) {
  paths.sort((String a, String b) => a.compareTo(b));
}

/// 在 [TargetPlatform.windows] 下调一次 `pickRealFilePaths`，**调完立刻把平台覆写归位**。
///
/// `testWidgets` 在测试体结束时就断言 foundation 的 debug 变量已经归位
/// （`debugAssertAllFoundationVarsUnset`），比 `tearDown` 早——覆写放 setUp/tearDown
/// 会让每条用例都以「The value of a foundation debug variable was changed」告败，
/// 和被测逻辑毫无关系。
Future<List<String>> _pickWithPlatform({
  required BuildContext context,
  required Set<String> allowedExtensions,
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  try {
    return await pickRealFilePaths(
      context: context,
      appModel: AppModel(testPlatformServices()),
      allowedExtensions: allowedExtensions,
    );
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

Future<BuildContext> _pumpAndCaptureContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext ctx) {
          captured = ctx;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

void main() {
  group('pickRealFilePaths 的每条返回路径都必须可增长（BUG-1574）', () {
    testWidgets('用户取消文件选择器（result == null）：结果可 sort、可 add', (
      WidgetTester tester,
    ) async {
      FilePicker.platform = _FakeFilePicker();
      final BuildContext context = await _pumpAndCaptureContext(tester);

      final List<String> paths = await _pickWithPlatform(
        context: context,
        allowedExtensions: <String>{'mp3', 'm4a'},
      );

      expect(paths, isEmpty);
      // 崩溃现场：不可变空列表在这一行抛 UnsupportedError。
      _sortLikeCallSitesDo(paths);
      paths.add('/tmp/a.mp3');
      expect(paths, <String>['/tmp/a.mp3']);
    });

    testWidgets('页面在选择器打开期间被销毁（context 已 unmount）：结果可 sort、可 add', (
      WidgetTester tester,
    ) async {
      FilePicker.platform = _FakeFilePicker();
      final BuildContext context = await _pumpAndCaptureContext(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(context.mounted, isFalse, reason: '这条测试要覆盖的就是 unmount 分支');

      final List<String> paths = await _pickWithPlatform(
        context: context,
        allowedExtensions: <String>{'mp3'},
      );

      expect(paths, isEmpty);
      _sortLikeCallSitesDo(paths);
      paths.add('/tmp/a.mp3');
      expect(paths, <String>['/tmp/a.mp3']);
    });

    testWidgets('正常选到文件：结果同样可 sort（并真的按字典序排好）', (WidgetTester tester) async {
      FilePicker.platform = _FakeFilePicker(
        FilePickerResult(<PlatformFile>[
          PlatformFile(name: 'b.mp3', size: 0, path: '/tmp/b.mp3'),
          PlatformFile(name: 'a.mp3', size: 0, path: '/tmp/a.mp3'),
        ]),
      );
      final BuildContext context = await _pumpAndCaptureContext(tester);

      final List<String> paths = await _pickWithPlatform(
        context: context,
        allowedExtensions: <String>{'mp3'},
      );

      _sortLikeCallSitesDo(paths);
      expect(paths, <String>['/tmp/a.mp3', '/tmp/b.mp3']);
    });
  });

  group('源码守卫：picker 不得交出不可变集合', () {
    test('real_path_directory_picker.dart 里没有任何 const 集合字面量', () {
      final File file =
          File('lib/src/media/import/real_path_directory_picker.dart');
      expect(file.existsSync(), isTrue,
          reason: '守卫的扫描目标没了（文件改名/挪窝）：先修扫描路径，别删守卫');

      // 必须用共享的等长掩码原语（手写的按行剥离既漏块注释，又会让「把断言
      // 字面量塞进注释」骗过守卫，见 test/tools/source_guard_adoption_test.dart）。
      final String code = maskComments(file.readAsStringSync());

      // 锚点哨兵：单文件守卫的塌陷形态就是「读到了别的东西却照样绿」。
      expect(code, contains('Future<List<String>> pickRealFilePaths('),
          reason: '扫到的不是那个 picker：守卫已经瞎了');
      expect(code, contains('Future<List<String>> _fallbackPickFiles('),
          reason: '扫到的不是那个 picker：守卫已经瞎了');

      // `const []` / `const <String>[]` / `const {}` / `const <String>{}` 全禁。
      // 这个文件是一层薄薄的选择器门面，它交出去的每个集合都会被调用方就地
      // sort / add；这里不留「哪些 const 是安全的」这种特例判断，一律不许有。
      final RegExp constCollection =
          RegExp(r'const\s*(<[^>\n]*>)?\s*[\[{]', multiLine: true);
      final List<String> offenders = <String>[];
      for (final RegExpMatch m in constCollection.allMatches(code)) {
        final int lineNo =
            '\n'.allMatches(code.substring(0, m.start)).length + 1;
        offenders.add('第 $lineNo 行：${m.group(0)!.trim()}');
      }

      expect(
        offenders,
        isEmpty,
        reason: 'BUG-1574：这个文件交出去的集合会被调用方就地 sort（books.part.dart 的 '
            'paths.sort / audiobook.part.dart 的 ..sort 级联 / 两个导入对话框），'
            'Dart 常量集合是 Unmodifiable*，sort 与 add 无条件抛 UnsupportedError，'
            '空集合照抛。返回可增长集合，别为了省一次分配改回去：\n'
            '${offenders.join('\n')}',
      );
    });
  });
}
