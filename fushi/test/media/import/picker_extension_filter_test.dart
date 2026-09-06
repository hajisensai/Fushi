// BUG-2099：安卓文件选择器把 `.mdx` / `.ass` 这类扩展名**置灰点不动**。
//
// 用户两次报同一个根因：「文件选择器直接对 mdx 是灰的」（导词典）、「导入视频字幕
// 的时候只能选 srt 不能选 ass」。
//
// 根因不在业务页，在「把扩展名过滤交给平台」这件事本身：
// - 安卓 SAF 只认 MIME，不认扩展名。file_picker 的 `FileUtils.getMimeTypes()`
//   逐个扩展名查 `MimeTypeMap.getSingleton().getMimeTypeFromExtension()`，
//   **查不到就 `continue` 静默跳过**，剩下的才进 `Intent.EXTRA_MIME_TYPES`。
//   于是 `['zip','dsl','mdx','ifo','css']` 只剩 `application/zip` + `text/css`，
//   `['srt','vtt','ass','ssa']` 只剩 srt/vtt——`.mdx` / `.dsl` / `.ifo` / `.ass` /
//   `.ssa` 在选择器里全部灰掉。
// - iOS 的 `dyn.*` UTI 是同一个病（老代码只治了 iOS 半边）。
//
// 所以移动端一律「`FileType.any` 打开选择器 + Dart 端按扩展名校验」，桌面维持原生
// 过滤（桌面对话框直接吃扩展名字符串，可靠，且选择器里只列相关文件体验更好）。
//
// 这里是**行为测试**而不是源码扫描：把 `FilePicker.platform` 换成会记录入参的假
// 实现，真的走一遍两个公开原语，断言「传给平台的 type / allowedExtensions」和
// 「Dart 端过滤后的结果」。改回 `FileType.custom` 必红。
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:path/path.dart' as p;

/// 假 file_picker：记录平台**实际收到**的过滤参数，并交回指定的文件列表。
class _RecordingFilePicker extends FilePicker {
  _RecordingFilePicker(this.returnedPaths);

  /// 平台交回的文件路径（模拟用户在选择器里选中的东西）。
  final List<String> returnedPaths;

  FileType? lastType;
  List<String>? lastAllowedExtensions;
  bool? lastWithData;
  bool? lastAllowMultiple;
  int calls = 0;

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
  }) async {
    calls++;
    lastType = type;
    lastAllowedExtensions = allowedExtensions;
    lastWithData = withData;
    lastAllowMultiple = allowMultiple;
    return FilePickerResult(<PlatformFile>[
      for (final String path in returnedPaths)
        PlatformFile(name: p.basename(path), size: 0, path: path),
    ]);
  }
}

/// 在指定平台下拿一个真 [BuildContext] 跑 [body]。
///
/// 平台覆写必须在**测试体结束前**归位：`testWidgets` 在体尾就断言 foundation 的
/// debug 变量已复原（`debugAssertAllFoundationVarsUnset`），比 `tearDown` 早，放
/// tearDown 会让每条用例都以「foundation debug variable was changed」告败——与被测
/// 逻辑无关（既有 real_path_picker_growable_test 踩过同一个坑）。
Future<T> _onPlatform<T>(
  WidgetTester tester,
  TargetPlatform platform,
  Future<T> Function(BuildContext context) body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return await body(captured);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// 词典导入真实使用的扩展名集（`dictionary_dialog_page._importDictionaryFiles`）。
const Set<String> kDictionaryExtensions = <String>{
  'zip',
  'dsl',
  'mdx',
  'ifo',
  'css',
};

/// 视频字幕导入真实使用的扩展名集（`subtitle.part.dart` / `home_video_page`）。
const Set<String> kSubtitleExtensions = <String>{'srt', 'vtt', 'ass', 'ssa'};

void main() {
  testWidgets('安卓：mdx 不再交给平台过滤，选中即被接受（BUG-2099 原始症状）', (
    WidgetTester tester,
  ) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      r'D:\dicts\LDOCE5++ V 2-15.mdx',
    ]);
    FilePicker.platform = fake;

    final String? path = await _onPlatform(
      tester,
      TargetPlatform.android,
      (BuildContext context) => pickSystemFilePath(
        context: context,
        allowedExtensions: kDictionaryExtensions,
      ),
    );

    expect(
      fake.lastType,
      FileType.any,
      reason:
          '安卓必须用 FileType.any 打开 SAF：custom 会被 MimeTypeMap 静默丢掉 '
          'mdx/dsl/ifo，选择器里那些文件是灰的',
    );
    expect(
      fake.lastAllowedExtensions,
      isNull,
      reason: '扩展名不能传给平台——传了就等于让 SAF 按 MIME 过滤',
    );
    expect(path, r'D:\dicts\LDOCE5++ V 2-15.mdx');
  });

  testWidgets('安卓：ass/ssa 字幕同样能选中（用户报「只能选 srt」）', (WidgetTester tester) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      '/sd/anime/ep01.ass',
    ]);
    FilePicker.platform = fake;

    final String? path = await _onPlatform(
      tester,
      TargetPlatform.android,
      (BuildContext context) => pickSystemFilePath(
        context: context,
        allowedExtensions: kSubtitleExtensions,
      ),
    );

    expect(fake.lastType, FileType.any);
    expect(path, '/sd/anime/ep01.ass');
  });

  testWidgets('安卓：扩展名不合格的选中仍被 Dart 端挡下（不过滤 ≠ 不校验）', (
    WidgetTester tester,
  ) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      '/sd/anime/ep01.mp4',
    ]);
    FilePicker.platform = fake;

    final String? path = await _onPlatform(
      tester,
      TargetPlatform.android,
      (BuildContext context) => pickSystemFilePath(
        context: context,
        allowedExtensions: kSubtitleExtensions,
      ),
    );

    expect(path, isNull, reason: '平台不过滤了，Dart 端就必须自己挡住不支持的格式');
  });

  testWidgets('iOS：维持 any + Dart 端过滤（dyn.* UTI 回归保护）', (
    WidgetTester tester,
  ) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      '/Files/ep01.srt',
    ]);
    FilePicker.platform = fake;

    final String? path = await _onPlatform(
      tester,
      TargetPlatform.iOS,
      (BuildContext context) => pickSystemFilePath(
        context: context,
        allowedExtensions: kSubtitleExtensions,
      ),
    );

    expect(fake.lastType, FileType.any);
    expect(path, '/Files/ep01.srt');
  });

  testWidgets('桌面：维持平台原生过滤（对话框直接吃扩展名，可靠）', (WidgetTester tester) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      r'D:\dicts\a.mdx',
    ]);
    FilePicker.platform = fake;

    await _onPlatform(
      tester,
      TargetPlatform.windows,
      (BuildContext context) => pickSystemFilePath(
        context: context,
        allowedExtensions: kDictionaryExtensions,
      ),
    );

    expect(
      fake.lastType,
      FileType.custom,
      reason: '桌面降级成 any 会让用户在一堆无关文件里翻找，属于无谓退化',
    );
    expect(fake.lastAllowedExtensions, containsAll(<String>['mdx', 'dsl']));
  });

  testWidgets('pickFilesByExtensions：安卓下只留合格条目，保留 PlatformFile 语义', (
    WidgetTester tester,
  ) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      '/sd/subs/ep01.ass',
      '/sd/subs/cover.mp4',
      '/sd/subs/ep02.ssa',
    ]);
    FilePicker.platform = fake;

    final FilePickerResult? result = await _onPlatform(
      tester,
      TargetPlatform.android,
      (BuildContext context) => pickFilesByExtensions(
        context: context,
        allowedExtensions: kSubtitleExtensions,
        allowMultiple: true,
      ),
    );

    expect(fake.lastType, FileType.any);
    expect(fake.lastAllowMultiple, isTrue);
    expect(result?.files.map((PlatformFile f) => f.name).toList(), <String>[
      'ep01.ass',
      'ep02.ssa',
    ]);
  });

  testWidgets('pickFilesByExtensions：全部不合格返回 null，不让调用方的 .single 抛', (
    WidgetTester tester,
  ) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      '/sd/subs/cover.mp4',
    ]);
    FilePicker.platform = fake;

    final FilePickerResult? result = await _onPlatform(
      tester,
      TargetPlatform.android,
      (BuildContext context) => pickFilesByExtensions(
        context: context,
        allowedExtensions: kSubtitleExtensions,
      ),
    );

    expect(
      result,
      isNull,
      reason:
          '交回空 files 会让 `result?.files.single` 抛 StateError——'
          '多个调用点都是这么读结果的',
    );
  });

  testWidgets('pickFilesByExtensions：withData 等参数原样透传给平台', (
    WidgetTester tester,
  ) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      '/dl/a.torrent',
    ]);
    FilePicker.platform = fake;

    final FilePickerResult? result = await _onPlatform(
      tester,
      TargetPlatform.android,
      (BuildContext context) => pickFilesByExtensions(
        context: context,
        allowedExtensions: <String>['torrent'],
        withData: true,
      ),
    );

    expect(
      fake.lastWithData,
      isTrue,
      reason: '手动添加 torrent 靠 bytes 落盘，透传丢了这个参数功能就断了',
    );
    expect(result?.files.single.name, 'a.torrent');
  });

  testWidgets('空扩展名集 = 不过滤：任何平台都直接 any，不做 Dart 端校验', (
    WidgetTester tester,
  ) async {
    final _RecordingFilePicker fake = _RecordingFilePicker(<String>[
      '/sd/whatever.bin',
    ]);
    FilePicker.platform = fake;

    final FilePickerResult? result = await _onPlatform(
      tester,
      TargetPlatform.android,
      (BuildContext context) => pickFilesByExtensions(context: context),
    );

    expect(fake.lastType, FileType.any);
    expect(fake.lastAllowedExtensions, isNull);
    expect(result?.files.single.name, 'whatever.bin');
  });
}
