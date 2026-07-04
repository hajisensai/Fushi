import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1133 源码守卫：缺失的本地视频除「删除」外必须提供「重新选择文件」重链路径。
///
/// 断言 `_relinkMissingResource` 存在且：① 经既有统一拾取 [pickRealFilePath]
/// （TODO-1112 的真实路径拾取：安卓 SAF 真实路径 / 桌面 file_picker）拿新路径，不新造
/// 第二套文件通道；② 经 `updateLocalMediaPaths(..., videoPath:` 持久化重链；③ 缺失
/// 对话框与缺失态 inline 正文都接了 `video_resource_missing_relink` 动作。纯字符串
/// 静态守卫，不跑 libmpv / 拾取器。防后续重构误删重链接线，回归成「只能删」。
void main() {
  const String pagePath =
      'lib/src/pages/implementations/video_hibiki_page.dart';
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

  test('缺失对话框与 inline 正文都提供「重新选择文件」动作', () {
    // i18n 按钮文案 key 至少出现两处（对话框 + inline 正文），确保两个入口都有重链。
    final int count = 'video_resource_missing_relink'.allMatches(source).length;
    expect(count, greaterThanOrEqualTo(2), reason: '缺失对话框与缺失态正文都要有「重新选择文件」按钮');
    // 缺失态选择 enum 必须含 relink 分支。
    expect(source.contains('_MissingResourceChoice.relink'), isTrue,
        reason: '缺失态选择必须含 relink');
  });
}
