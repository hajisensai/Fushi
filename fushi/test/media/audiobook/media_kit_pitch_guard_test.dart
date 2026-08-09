import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（BUG-070）：有声书拖动倍速在桌面端（media_kit / libmpv）闪退。
///
/// 根因——`JustAudioMediaKit.pitch` 默认 `true`，此时 media_kit 的 `setRate`
/// 会在每次调速时重写 mpv 的 `af` 音频滤镜图（`scaletempo:scale=…`）；在 Windows
/// 上播放过程中反复重配音频滤镜图会触发 libmpv 进程级崩溃（native segfault，
/// Dart 的 try/catch 与 `runZonedGuarded` 都拦不住，故表现为「闪退」）。
///
/// 修复——main.dart 启动时显式 `JustAudioMediaKit.pitch = false`，让调速改走 mpv
/// 原生 `speed` 属性（不重配滤镜图），mpv 默认 `audio-pitch-correction=yes` 仍保留
/// 音高。本 app 无变调 UI、从不调 `setPitch`，关掉 pitch 控制零功能损失。
///
/// native 崩溃无法在 host 单测里复现（flutter test 没有 media_kit 后端），故用
/// 源码扫描守卫钉住这条启动配置不被回归删除 / 改回 true（与 BUG-031/034 同范式）。
void main() {
  test('main.dart disables JustAudioMediaKit pitch before init (BUG-070)', () {
    final String src = File('lib/main.dart').readAsStringSync();

    // 必须显式把 pitch 设为 false（默认 true 会走崩溃的 af 滤镜重配路径）。
    expect(
      RegExp(r'JustAudioMediaKit\.pitch\s*=\s*false').hasMatch(src),
      isTrue,
      reason: '必须 JustAudioMediaKit.pitch = false，否则调速走崩溃的 af 滤镜重配路径',
    );

    // 绝不能把它设回 true（防止有人「为了变调」误改回去而不知会复发崩溃）。
    expect(
      RegExp(r'JustAudioMediaKit\.pitch\s*=\s*true').hasMatch(src),
      isFalse,
      reason: 'pitch=true 会复发 BUG-070 桌面闪退',
    );

    // 配置必须在 ensureInitialized() 之前（pitch 在 Player 创建时读取，
    // 设置必须先于任何播放器构造）。
    final int pitchIdx =
        src.indexOf(RegExp(r'JustAudioMediaKit\.pitch\s*=\s*false'));
    final int ensureIdx = src.indexOf('JustAudioMediaKit.ensureInitialized()');
    expect(pitchIdx, greaterThanOrEqualTo(0));
    expect(ensureIdx, greaterThanOrEqualTo(0));
    expect(
      pitchIdx < ensureIdx,
      isTrue,
      reason: 'pitch 必须在 ensureInitialized() 之前设置',
    );
  });
}
