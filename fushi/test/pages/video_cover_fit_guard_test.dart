import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-616 阶段 C 守卫：视频封面必须完整显示（不裁切）。
///
/// 根因：ffmpeg 抽的视频封面是 16:9（宽高比 ~1.78）原图，封面卡槽比它更窄
/// （约 1.3–1.55），`BoxFit.cover` 会把源裁进卡槽，左右/上下被切掉。
/// 修复：三处视频封面渲染（本地 `_buildCover` + 远端 `_buildRemoteVideoCover`
/// 的缓存图与网络图）改用 `BoxFit.contain`，整帧完整显示、上下留少量空带。
///
/// 这是源码扫描守卫——视频封面是 UI 渲染，难做像素断言，故锚定到封面渲染
/// 函数体，断言不含裁切类 fit（`BoxFit.cover` / `BoxFit.fitHeight`）、含
/// `BoxFit.contain`，防回归到裁切。
void main() {
  const String path = 'lib/src/pages/implementations/home_video_page.dart';

  test(
      'video covers render with BoxFit.contain (complete, no crop) — TODO-616C',
      () {
    final String source = File(path).readAsStringSync();

    // 远端云视频封面：缓存文件 + 网络图两处。
    final String remoteCover =
        _functionSource(source, 'Widget _buildRemoteVideoCover(');
    // 本地视频封面。
    final String localCover = _functionSource(source, 'Widget _buildCover(');

    for (final entry in <String, String>{
      '_buildRemoteVideoCover': remoteCover,
      '_buildCover': localCover,
    }.entries) {
      final String name = entry.key;
      final String body = entry.value;

      expect(
        body,
        isNot(contains('fit: BoxFit.cover')),
        reason: '$name 不得用 BoxFit.cover——会把 16:9 源裁进更窄的卡槽，'
            '裁掉左右（TODO-616 阶段 C 回归）',
      );
      expect(
        body,
        isNot(contains('fit: BoxFit.fitHeight')),
        reason: '$name 不得用 BoxFit.fitHeight——卡槽比源更窄，fitHeight 会让'
            '宽度溢出被裁掉左右，仍是裁切',
      );
      expect(
        body,
        contains('fit: BoxFit.contain'),
        reason: '$name 必须用 BoxFit.contain 让整帧完整显示、不裁切',
      );
    }

    // 远端封面两处（缓存 Image.file + 网络 Image.network）都必须 contain。
    expect(
      RegExp(r'fit: BoxFit\.contain').allMatches(remoteCover).length,
      2,
      reason: '远端缓存图与网络图两处都必须用 BoxFit.contain',
    );
    expect(
      RegExp(r'fit: BoxFit\.contain').allMatches(localCover).length,
      1,
      reason: '本地视频封面必须用 BoxFit.contain',
    );
  });
}

/// 截取从 [startToken] 起到下一个顶层 `  Widget xxx(` 方法定义之前的源码片段。
String _functionSource(String source, String startToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final RegExp nextWidget = RegExp(r'\n  Widget [_A-Za-z0-9]+\(');
  final RegExpMatch? next = nextWidget.firstMatch(
    source.substring(start + startToken.length),
  );
  final int end =
      next == null ? source.length : start + startToken.length + next.start + 1;
  return source.substring(start, end);
}
