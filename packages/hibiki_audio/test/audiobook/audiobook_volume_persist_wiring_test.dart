import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-031）：控制器侧的音量持久化原语必须与 speed 同型存在——
/// `onVolumePersist` 回调、`setVolume` 触发它、`load` 应用 `initialVolume`。
/// 运行期 `setVolume` 需真实 just_audio player，单测不便驱动，故用源码守卫钉死
/// 这三件，配合 reader 侧接线守卫 + repo 往复测试形成完整防回归。
void main() {
  test('AudiobookPlayerController has volume persistence primitives', () {
    final String src =
        File('lib/src/audiobook/audiobook_controller.dart').readAsStringSync();

    // 回调声明存在。
    expect(src, contains('onVolumePersist'));
    // load 接受并应用初值。
    expect(src, contains('initialVolume'));
    // setVolume 体内触发 persist（钳值后比对 prev，同 speed）。
    final int setVolumeStart = src.indexOf('Future<void> setVolume(');
    expect(setVolumeStart, isNonNegative);
    final int setVolumeEnd = src.indexOf('\n  }', setVolumeStart);
    final String setVolumeBody = src.substring(setVolumeStart, setVolumeEnd);
    expect(setVolumeBody, contains('onVolumePersist'),
        reason: 'setVolume 必须在值变化时落 onVolumePersist');

    // speed 既有原语不许被回归删除。
    expect(src, contains('onSpeedPersist'));
    expect(src, contains('initialSpeed'));
  });
}
