// BUG-1270：恢复起播位置改走 libmpv `start` 加载参数后的纯函数 + 源码契约守卫。
//
// 真正的行为验证在真机集成测试 `integration_test/video_resume_seek_lands_test.dart`
// （headless 跑不了真实 libmpv loadfile）。本文件守住两件可在 host 验的事：
//   ① `start` 值的格式化（喂给 mpv 的字符串）；
//   ② `load()` 里的**顺序契约**——`start` 必须在 `player.open(` 之前下发、且必须复位。
//      顺序一旦被后来的重构挪动，修复就静默失效（回到「open 后 seek 被 loadfile 覆盖」），
//      而任何 host 侧行为测试都抓不到，故用源码扫描守卫钉死。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';

/// 被守卫的源文件（相对 `hibiki/` 包根，`flutter test` 的 cwd）。
const String _kControllerPath = 'lib/src/media/video/video_player_controller.dart';

void main() {
  group('BUG-1270 formatMpvStartSeconds', () {
    test('毫秒转 mpv 秒值字符串', () {
      expect(formatMpvStartSeconds(45000), '45.000');
      expect(formatMpvStartSeconds(0), '0.000');
      expect(formatMpvStartSeconds(1), '0.001');
      expect(formatMpvStartSeconds(3661500), '3661.500');
    });

    test('负值 clamp 到 0（不给 mpv 喂负 start）', () {
      expect(formatMpvStartSeconds(-1), '0.000');
      expect(formatMpvStartSeconds(-45000), '0.000');
    });
  });

  group('BUG-1270 load() 顺序契约（源码守卫）', () {
    late String source;

    setUpAll(() {
      final File f = File(_kControllerPath);
      expect(f.existsSync(), isTrue,
          reason: '守卫目标不存在：$_kControllerPath（测试 cwd 应为 hibiki/ 包根）');
      source = f.readAsStringSync();
    });

    test('start 下发排在 player.open( 之前', () {
      final int armIdx = source.indexOf('applyMpvStartPosition(');
      final int openIdx = source.indexOf('player.open(');
      expect(armIdx, greaterThanOrEqualTo(0),
          reason: 'load() 必须经 applyMpvStartPosition 把恢复位置作为加载参数下发；'
              '缺失即回退到「open 后 seek」，Android 上必被 loadfile 覆盖。');
      expect(openIdx, greaterThanOrEqualTo(0), reason: '找不到 player.open( 调用');
      expect(armIdx, lessThan(openIdx),
          reason: 'applyMpvStartPosition 必须在 player.open( **之前**调用。'
              'mpv 的 `start` 只对随后的 loadfile 生效，写在 open 之后等于没写。');
    });

    test('start 用完必须复位（否则下一集继承上一集的起播秒数）', () {
      expect(source.contains('clearMpvStartPosition('), isTrue,
          reason: '`start` 是全局选项，换集/画质切档复用同一 Player；'
              '不复位会让下一次 loadfile 从上一集断点起播。');
    });

    test('near-end 复核翻转时把 mpv 拉回 0', () {
      // startArmed 分支里必须有 seek(Duration.zero)：open 前按断点设了 start，若真实
      // duration 显示已快看完，mpv 已停在断点，不显式拉回就会「从结尾几秒开始」。
      expect(source.contains('player.seek(Duration.zero)'), isTrue,
          reason: 'near-end 复核翻转时必须 seek(Duration.zero) 把已按 start 定位的 mpv '
              '拉回开头，否则 near-end 语义在 start 路径下失效。');
    });
  });
}
