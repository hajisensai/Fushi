import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1133 / BUG-805 源码守卫：缺失的本地视频除「删除」外必须提供真实的重链/重导入
/// 路径。
///
/// 断言 `_relinkMissingResource` 存在且：① 经既有统一拾取 [pickRealFilePath]
/// （TODO-1112 的真实路径拾取：安卓 SAF 真实路径 / 桌面 file_picker）拿新路径，不新造
/// 第二套文件通道；② 经 `updateLocalMediaPaths(..., videoPath:` 持久化重链。
///
/// BUG-805：原来「重新选择文件」是独立按钮、「重新导入」是空操作 `nav.pop()`（用户点了
/// 「没反应」）。现合并为单一「重新导入」真动作 [_reimportMissingResource]——单视频委托
/// 上面的重链、播放列表打开 [VideoImportDialog]。故本守卫改为断言缺失对话框与 inline
/// 正文都把「重新导入」接到 `_reimportMissingResource`（不再有独立 relink 按钮/枚举/key，
/// 也不再有空操作 pop）。纯字符串静态守卫，不跑 libmpv / 拾取器。
void main() {
  const String pagePath =
      'lib/src/pages/implementations/video_fushi_page.dart';
  late String source;

  setUpAll(() {
    source = File(pagePath).readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('_relinkMissingResource 复用统一拾取并持久化重链 videoPath', () {
    final int start = source.indexOf('Future<void> _relinkMissingResource(');
    expect(start, greaterThanOrEqualTo(0), reason: '缺失视频必须提供「重新选择文件」重链动作');
    // 取到下一个同级方法签名前，圈定方法体（_confirmMissingResourceDelete 紧随其后）。
    final int end =
        source.indexOf('Future<void> _confirmMissingResourceDelete(');
    expect(end, greaterThan(start), reason: '_relinkMissingResource 方法体边界解析失败');
    final String body = source.substring(start, end);

    final int pickAt = body.indexOf('pickRealFilePath(');
    expect(pickAt, greaterThanOrEqualTo(0),
        reason: '必须复用 pickRealFilePath（TODO-1112 真实路径拾取），不新造文件通道');
    final int persistAt = body.indexOf('updateLocalMediaPaths(');
    expect(persistAt, greaterThan(pickAt),
        reason: '拾取到新路径后必须经 updateLocalMediaPaths 持久化重链');
    // 只重链 videoPath（不动进度 / 字幕 / 音轨等其它列）。
    expect(body.contains('videoPath: newPath'), isTrue,
        reason: '重链只写新 videoPath');
    // 重链后原地重新载入播放（复用单视频加载路径）。
    expect(body.contains('_loadSingle('), isTrue, reason: '重链后必须重新载入播放');
  });

  test('BUG-805: 缺失对话框与 inline 正文的「重新导入」都接真动作，无空操作/无独立 relink', () {
    // 「重新导入」真动作方法存在，且单视频分支委托既有重链 _relinkMissingResource
    // （保留进度 / 字幕 / 音轨），非单视频打开 VideoImportDialog 真导入。
    expect(
        source.contains(
            'Future<void> _reimportMissingResource(VideoBookRow? row)'),
        isTrue,
        reason: '缺失态「重新导入」必须有真动作方法 _reimportMissingResource');
    expect(source.contains('await _relinkMissingResource(row);'), isTrue,
        reason: '单视频重新导入应委托 _relinkMissingResource 重链');
    expect(source.contains('VideoImportDialog(repo: widget.repo)'), isTrue,
        reason: '非单视频重新导入应打开 VideoImportDialog 走真实导入');

    // 弹窗版 switch 分支与 inline 正文按钮都路由到 _reimportMissingResource（两个入口）。
    expect(source.contains('await _reimportMissingResource(row);'), isTrue,
        reason: '缺失对话框「重新导入」必须调 _reimportMissingResource（非空 pop）');
    expect(source.contains('unawaited(_reimportMissingResource(row))'), isTrue,
        reason: '缺失态正文「重新导入」按钮必须调 _reimportMissingResource（非空 pop）');

    // 合并后不再有独立「重新选择文件」按钮 / 枚举项 / i18n key。
    expect(source.contains('_MissingResourceChoice.relink'), isFalse,
        reason: 'relink 枚举项应已移除（合并进 reimport）');
    expect(source.contains('video_resource_missing_relink'), isFalse,
        reason: '未用的 video_resource_missing_relink key 应已移除');
  });
}
