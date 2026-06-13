import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-031 / TODO-291 阶段2）：有声书音量持久化是「load 读 + 改写 persist」
/// 两段接线，任一段被回归删掉都会让音量重新变成「不保存」。TODO-291 阶段2 把控制器创建 +
/// 音频文件/偏好解析 + persist 接线从 reader 页两条 init 路径下沉到共用的
/// [AudiobookSessionLauncher]（reader + 书架共用）。这条钉住 launcher 仍读出音量/速度
/// （readVolume/readSpeed）并装 persist 回调（onVolumePersist/onSpeedPersist），且会话
/// 把它们传给 load（initialVolume/initialSpeed）。
void main() {
  test('session launcher wires volume + speed read + persist + initial', () {
    final String launcher = File(
      'lib/src/media/audiobook/audiobook_session_launcher.dart',
    ).readAsStringSync();
    final String session = File(
      'lib/src/media/audiobook/audiobook_session.dart',
    ).readAsStringSync();

    // launcher 装 persist 回调 + 从 repo 读出音量/速度。
    expect(launcher.contains('onVolumePersist'), isTrue,
        reason: 'launcher 要装 onVolumePersist 回调');
    expect(RegExp(r'readVolume\(').hasMatch(launcher), isTrue,
        reason: 'launcher 要从 repo 读出持久化音量');
    expect(launcher.contains('onSpeedPersist'), isTrue,
        reason: 'launcher 要装 onSpeedPersist 回调');
    expect(RegExp(r'readSpeed\(').hasMatch(launcher), isTrue,
        reason: 'launcher 要从 repo 读出持久化速度');

    // session 把读出的初值传给控制器 load。
    expect(session.contains('initialVolume:'), isTrue,
        reason: 'session.start 要把音量作为 initialVolume 传给 load');
    expect(session.contains('initialSpeed:'), isTrue,
        reason: 'session.start 要把速度作为 initialSpeed 传给 load');
  });
}
