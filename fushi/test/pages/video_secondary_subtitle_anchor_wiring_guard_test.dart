import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1592 接线守卫：字幕命中项带出的 cue **必须**一路走到查词/制卡锚点。
///
/// widget 测试（`test/media/video/video_secondary_subtitle_mining_anchor_test.dart`）能证明
/// overlay 把「被点那条 cue」回传给了页面，但证明不了页面**转手把它当锚点用**——`onCharTap`
/// 多收一个参数、随手丢掉也照样编译通过。而丢掉的后果正是本 bug 的原状：主字幕关掉、只开
/// 副字幕时锚点恒 null → 制卡区间塌成 `0..0` → 句子音频空 + 封面抽视频第 0 秒的片头黑帧
/// （用户报「制卡黑屏」）。故在此对这几行接线做源码断言。
void main() {
  String read(String rel) {
    final File f = File(rel);
    expect(f.existsSync(), isTrue, reason: '缺文件: $rel');
    return f.readAsStringSync();
  }

  test('_handleSubtitleLookupTap 必须把命中 cue 作为 overrideCue 透传给 _lookupAt', () {
    final String page =
        read('lib/src/pages/implementations/video_fushi_page.dart');
    final int start = page.indexOf('void _handleSubtitleLookupTap(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = page.indexOf('\n  }', start);
    expect(end, greaterThan(start));
    final String body = page.substring(start, end);

    expect(body.contains('AudioCue? cue'), isTrue,
        reason: '点击查词入口必须收下命中项带出的所属 cue');
    expect(body.contains('overrideCue: cue'), isTrue,
        reason: '收下了却不作为 overrideCue 透传 = 锚点仍去主字幕流猜 → 只开副字幕时制卡区间 0..0');
  });

  test('hover 查词入口同样透传命中 cue（与点击同一条链路）', () {
    final String page =
        read('lib/src/pages/implementations/video_fushi_page.dart');
    final int start = page.indexOf('void _handleSubtitleHoverLookup(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = page.indexOf('\n  }', start);
    final String body = page.substring(start, end);

    expect(body.contains('AudioCue? cue'), isTrue);
    expect(
        RegExp(r'_handleSubtitleLookupTap\([^;]*cue\)').hasMatch(body), isTrue,
        reason: 'hover 换词丢掉 cue 会让 Shift-悬停查词制出的卡回到黑帧');
  });

  test('查词锚点兜底解析走有效流 miningCues（主流为空即副流），不再硬认主字幕流', () {
    final String favorite = read(
        'lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart');
    expect(favorite.contains('cues: controller.miningCues'), isTrue,
        reason: '硬认 controller.cues 会让只开副字幕时按位置解析恒 null');
    expect(favorite.contains('cues: controller.cues'), isFalse,
        reason: '不得回潮到只认主字幕流');
  });

  test('制卡区间与上下 N 句上下文都按有效流/锚点所属流取', () {
    final String mining = read(
        'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart');
    expect(mining.contains('cues: controller.miningCues'), isTrue,
        reason: '_resolveVideoMiningRange 的按位置兜底必须走有效流');
    expect(mining.contains('controller.cueStreamOwning(anchor)'), isTrue,
        reason: '上下 N 句必须在锚点所属的那条流里取邻句，否则副字幕锚点 indexOf 恒 -1 静默失效');
  });
}
