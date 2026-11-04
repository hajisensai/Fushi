import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_immersive_mode.dart';

import '../../helpers/source_guard.dart' show compactCode;

/// LVLfqlFLVA：沉浸锁定时长按画面仍会临时加速。
///
/// 根因：长按临时倍速入口 `_handleVideoLongPressStart`（video_fushi/speed.part.dart）
/// 只判了「是否落在控件上」，从不看沉浸锁定 / 沉浸档位；同为指针播放控制的触摸双击
/// seek、滚轮、右键菜单都早已按档位门控。修法：判据收进纯函数
/// [videoImmersiveAllowsLongPressSpeed]（只有 full 档放行），入口在接管倍速前先过它。
///
/// ① 纯函数真值表（四档 × 锁 / 未锁）；② 接线守卫：入口必须在写恢复位之前判档位
/// （否则 move / end 会拿着残留的恢复位继续改倍速）。
void main() {
  group('videoImmersiveAllowsLongPressSpeed', () {
    test('未锁定：任何档位都放行（长按是普通播放手势）', () {
      for (final VideoImmersiveMode mode in VideoImmersiveMode.values) {
        expect(
          videoImmersiveAllowsLongPressSpeed(
            immersiveLocked: false,
            mode: mode,
          ),
          isTrue,
          reason: '$mode',
        );
      }
    });

    test('锁定：只有 full 档放行', () {
      for (final VideoImmersiveMode mode in VideoImmersiveMode.values) {
        expect(
          videoImmersiveAllowsLongPressSpeed(immersiveLocked: true, mode: mode),
          mode == VideoImmersiveMode.full,
          reason: '$mode：沉浸锁定挡住指针误触，长按加速与双击 seek 同档',
        );
      }
    });
  });

  test('接线：长按入口在接管倍速之前按沉浸档位早退', () {
    final String src = File(
      'lib/src/pages/implementations/video_fushi/speed.part.dart',
    ).readAsStringSync();
    final int start = src.indexOf(
      'void _handleVideoLongPressStart(LongPressStartDetails details) {',
    );
    expect(start, greaterThanOrEqualTo(0));
    final int end = src.indexOf('void _handleVideoLongPressMoveUpdate', start);
    final String body = compactCode(src.substring(start, end));
    final int gate = body.indexOf(
      compactCode(
        'if (!videoImmersiveAllowsLongPressSpeed( '
        'immersiveLocked: _immersiveLocked.value, '
        'mode: _videoImmersiveMode,',
      ),
    );
    final int takeOver = body.indexOf(
      compactCode('_longPressPreviousSpeed = _playbackSpeed;'),
    );
    expect(gate, greaterThanOrEqualTo(0), reason: '入口必须过沉浸档位判据');
    expect(takeOver, greaterThan(gate), reason: '判据必须先于写恢复位 / 改倍速');
  });
}
