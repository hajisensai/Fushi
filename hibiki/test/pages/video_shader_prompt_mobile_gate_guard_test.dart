import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-874）：手机端不再弹「开启超分(Anime4K)」首次使用提示。
///
/// 不变式：[_showAnime4kFirstUsePromptIfNeeded] 方法体最开头必须有移动端
/// （Android / iOS）的 early-return，纯抑制提示。代码自身的
/// `video_shader_mobile_perf_hint` 文案警告手机超分掉帧、发热，再主动劝用户开启
/// 自相矛盾；故手机端整段提示直接跳过，仅桌面端保留。
///
/// 用源码扫描而非整页 widget pump：该提示路径深埋在 HomeVideoPage 的 _open /
/// _openRemote 导航里，依赖完整 AppModel + DB + 远端客户端，整页启动成本高且脆弱；
/// 平台 early-return 这条不变式正是本次需求的精确正面，源码扫描足以守住（与
/// video_experimental_markers_guard_test 同范式）。
String _read(String relative) {
  final File f = File(relative);
  if (!f.existsSync()) {
    throw StateError(
        'missing source: $relative (cwd=${Directory.current.path})');
  }
  return f.readAsStringSync();
}

/// 截取 [_showAnime4kFirstUsePromptIfNeeded] 方法体到下一个方法声明之间的源码切片，
/// 确保断言落在该方法范围内而非文件别处。
String _promptMethodBody(String src) {
  const String marker =
      'Future<void> _showAnime4kFirstUsePromptIfNeeded() async {';
  final int start = src.indexOf(marker);
  expect(start, greaterThan(0),
      reason: '应存在 _showAnime4kFirstUsePromptIfNeeded 方法');
  // 下一个方法是 _downloadAndEnableDefaultShaderTier；切到它为止。
  final int end =
      src.indexOf('_downloadAndEnableDefaultShaderTier', start + marker.length);
  expect(end, greaterThan(start),
      reason: '应能定位方法体边界（下一方法 _downloadAndEnableDefaultShaderTier）');
  return src.substring(start, end);
}

void main() {
  group('TODO-874：手机端抑制 Anime4K 首次提示', () {
    final String videoSrc =
        _read('lib/src/pages/implementations/home_video_page.dart');

    test('引入 foundation（defaultTargetPlatform / TargetPlatform）', () {
      expect(videoSrc.contains("import 'package:flutter/foundation.dart';"),
          isTrue,
          reason: '平台门控需要 defaultTargetPlatform，须引 foundation');
    });

    test('方法体内含移动端平台 early-return', () {
      final String body = _promptMethodBody(videoSrc);
      expect(body.contains('defaultTargetPlatform == TargetPlatform.android'),
          isTrue,
          reason: 'Android 应在该方法内被门控早退');
      expect(
          body.contains('defaultTargetPlatform == TargetPlatform.iOS'), isTrue,
          reason: 'iOS 应在该方法内被门控早退');
      // 平台判定后紧跟 return，构成 early-return（移动端直接跳过整段提示）。
      final int iosAt =
          body.indexOf('defaultTargetPlatform == TargetPlatform.iOS');
      final int returnAt = body.indexOf('return;', iosAt);
      expect(returnAt, greaterThan(iosAt),
          reason: '移动端平台判定后应紧跟 return（early-return 抑制提示）');
    });

    test('纯抑制：不在移动端早退路径置 videoAnime4kPromptShown 标记', () {
      final String body = _promptMethodBody(videoSrc);
      final int iosAt =
          body.indexOf('defaultTargetPlatform == TargetPlatform.iOS');
      final int returnAt = body.indexOf('return;', iosAt);
      final String gateSlice = body.substring(0, returnAt);
      expect(gateSlice.contains('setVideoAnime4kPromptShown'), isFalse,
          reason: '移动端为纯抑制，不应在早退前置位（保持零副作用，桌面端仍能首弹）');
    });
  });
}
