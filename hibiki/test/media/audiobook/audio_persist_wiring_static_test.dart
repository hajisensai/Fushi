import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-031）：有声书音量持久化是「load 读 + 改写 persist」两段接线，
/// 任一段被回归删掉都会让音量重新变成「不保存」。这条钉住 reader 页两条控制器
/// 初始化路径（audiobook / srt）都接上了音量读取/初值/持久化，并顺带钉住既有的
/// speed 接线不被一起删（speed 经核查配线正确，仅防回归）。
void main() {
  test('reader wires volume + speed persistence in both audio init paths', () {
    final String src = File(
      'lib/src/pages/implementations/reader_hibiki_page.dart',
    ).readAsStringSync();

    // 两条初始化路径（audiobook / srt）各一次音量接线 → 至少 2 次。
    expect(RegExp('onVolumePersist').allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: '两条控制器路径都要装 onVolumePersist 回调');
    expect(
        RegExp(r'readVolume\(').allMatches(src).length, greaterThanOrEqualTo(2),
        reason: '两条路径都要从 repo 读出持久化音量');
    expect(RegExp('initialVolume:').allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: '两条路径都要把读出的音量作为 initialVolume 传给 load');

    // speed 既有接线不许被回归删除。
    expect(RegExp('onSpeedPersist').allMatches(src).length,
        greaterThanOrEqualTo(2));
    expect(RegExp('initialSpeed:').allMatches(src).length,
        greaterThanOrEqualTo(2));
  });
}
