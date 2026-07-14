import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-801 守卫（源码扫描）：libmpv 默认 `sub-auto=exact` 会在 `player.open()` 加载文件时
/// 自动加载与视频**同名的 sidecar 外挂字幕**（`<video>.ass/.srt`），把它选成字幕轨经
/// media_kit 原生 `SubtitleView` 渲染，与 Hibiki 自己解析同一 sidecar 得到的可点
/// [VideoSubtitleOverlay] 叠成两条同句字幕（安卓等价 SubtitleView 尤其明显）。
///
/// 根治：字幕抑制（`sub-auto=no`）必须在 `player.open()` **之前**下发——open 之后再设已太迟
/// （sidecar 在 open 那一刻已随 `sub-auto=exact` 自动加载并选中）。
///
/// 本守卫锁定「`load()` 里第一处 `applySubtitleMpvPropertiesToPlayer(...`
/// `buildSubtitleSuppressionProperties())` 出现在 `await player.open(` 之前」这个顺序不变量，
/// 防止后续重构把抑制挪回 open 之后（回归 BUG-801）。纯字符串扫描，无需 libmpv/真机。
void main() {
  test('sub-auto=no suppression is applied BEFORE player.open() in load()', () {
    final File src = File(
      'lib/src/media/video/video_player_controller.dart',
    );
    expect(src.existsSync(), isTrue,
        reason: '找不到 video_player_controller.dart（路径随重构变了？）');
    final String text = src.readAsStringSync();

    final int openIdx = text.indexOf('await player.open(');
    expect(openIdx, greaterThan(0), reason: '找不到 player.open() 调用');

    // open 之前必须已经下发一次抑制（sub-auto=no）——否则 sidecar 已被 libmpv 自动加载。
    final String beforeOpen = text.substring(0, openIdx);
    final bool suppressedBeforeOpen = beforeOpen.contains(
      'buildSubtitleSuppressionProperties()',
    );
    expect(
      suppressedBeforeOpen,
      isTrue,
      reason:
          'BUG-801 回归：字幕抑制（buildSubtitleSuppressionProperties / sub-auto=no）'
          '必须在 `player.open()` **之前**下发，否则 libmpv 会在 open 时自动加载同名 sidecar '
          '字幕并经原生 SubtitleView 渲染，与可点 overlay 叠成双字幕。',
    );

    // 纯函数本身仍须把 sub-auto 关掉（防止有人把它改成只关 sub-visibility）。
    final File cfg = File('lib/src/media/video/video_mpv_config.dart');
    final String cfgText = cfg.readAsStringSync();
    final int fnIdx = cfgText
        .indexOf('Map<String, String> buildSubtitleSuppressionProperties');
    expect(fnIdx, greaterThan(0));
    final String fnBody = cfgText.substring(fnIdx, fnIdx + 200);
    expect(fnBody.contains("'sub-auto': 'no'"), isTrue,
        reason:
            'buildSubtitleSuppressionProperties 必须含 sub-auto=no（禁止 sidecar 自动加载）');
  });
}
