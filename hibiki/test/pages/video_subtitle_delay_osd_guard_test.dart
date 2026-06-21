import 'package:flutter_test/flutter_test.dart';
import 'video_hibiki_page_source_corpus.dart';

/// BUG-373 源码守卫：字幕音画延迟调整必须给**可见反馈**——调延迟后经左上角 mpv 式 OSD
/// 通知（与调速 `Icons.speed` 同范式），让用户在不打开快速设置面板时也看得到调整生效。
///
/// 修复前 `_setDelayMs` 只改 controller + 持久化 + setState，无任何 OSD/toast，
/// 表现为「调了没反馈」。media_kit OSD 时序跑不了 headless，故锁源码不变量。
void main() {
  late String src;
  setUpAll(() {
    src = readVideoHibikiSource();
  });

  String methodBody(String signature, String endMarker) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '需有 $signature');
    final int end = src.indexOf(endMarker, start + signature.length);
    expect(end, greaterThan(start), reason: '需有 $endMarker 作为 $signature 的段终点');
    return src.substring(start, end);
  }

  test('_setDelayMs 调延迟后经 _showOsd 给即时 OSD 反馈', () {
    final String body = methodBody(
      'Future<void> _setDelayMs(int delayMs) async {',
      'Future<void> _adjustVolume(double delta) async {',
    );
    expect(body.contains('_showOsd('), isTrue,
        reason: 'BUG-373：_setDelayMs 必须调 _showOsd 给可见反馈');
    expect(body.contains('t.video_subtitle_delay_osd(ms:'), isTrue,
        reason: 'OSD 文案用 i18n key video_subtitle_delay_osd（带 ms 参数）');
    expect(body.contains('Icons.sync_outlined'), isTrue,
        reason: 'OSD 图标用 Icons.sync_outlined（字幕同步语义）');
  });
}
