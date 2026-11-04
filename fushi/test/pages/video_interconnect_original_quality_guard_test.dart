import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 反馈 uaBRMzK_WM：画质菜单要有「原画」，选了就永不转码、自适应不接管。
///
/// 播放页在 headless test 里跑不起 media_kit（见
/// video_remote_default_subtitle_failure_guard_test），接线用源码守卫钉住；选档与
/// 取流语义本身由 `test/sync/interconnect_auto_quality_link_test.dart`（真 host +
/// 真 client）覆盖。
void main() {
  late String src;
  setUpAll(() => src = maskComments(readVideoFushiSource()));

  String methodBody(String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThan(-1), reason: '缺少 $signature');
    final int end = src.indexOf('\n  }\n', start);
    expect(end, greaterThan(start));
    return src.substring(start, end);
  }

  test('服务端档位面板在来源声明支持时列出「原画」行', () {
    final String panel = methodBody('Widget _buildQualitySidePanelBody(');
    final int gate = panel.indexOf('if (server.offersOriginalQuality)');
    expect(gate, greaterThan(-1));
    expect(
      panel.indexOf('index: kRemoteVideoQualityOriginal', gate),
      greaterThan(gate),
    );
    expect(panel, contains('t.video_quality_original'));
  });

  test('选「原画」写进 client，且被当作显式选档（自适应停）', () {
    final String sw = methodBody(
      'Future<void> _switchMediaServerQuality(int index)',
    );
    expect(sw, contains('kRemoteVideoQualityOriginal'));
    expect(sw, contains('if (target != kRemoteVideoQualityAuto) {'));
    // 旧写法 `index < 0 ? -1 : index` 会把原画哨兵抹成自动。
    expect(sw.contains('final int target = index < 0 ? -1 : index;'), isFalse);
  });

  test('自适应只在「自动」时接管：判据是 == 自动，而不是 < 0', () {
    final String restart = methodBody('void _restartAdaptiveQuality()');
    expect(
      restart,
      contains('client.qualityPresetIndex != kRemoteVideoQualityAuto'),
    );
    final String tick = methodBody('void _tickAdaptiveQuality()');
    expect(
      tick,
      contains('client.qualityPresetIndex != kRemoteVideoQualityAuto'),
    );
    expect(tick.contains('client.qualityPresetIndex >= 0'), isFalse);
  });

  test('自适应升到原画时 OSD 报「原画」而不是「自动」', () {
    final String apply = methodBody('Future<void> _applyAdaptiveQuality(');
    expect(apply, contains('kRemoteVideoQualityOriginal'));
    expect(apply, contains('_mediaServerQualityLabel('));
  });
}
