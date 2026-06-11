import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫（TODO-116）：**视频调速不闪退的根因不变量**。
///
/// 背景：有声书曾在 Windows 上一拖调速滑条就闪退（TODO-070/BUG-070）。根因是
/// `JustAudioMediaKit.pitch` 默认 `true` → media_kit 每次 `setRate` 都重写 libmpv
/// 的 `af`（scaletempo）用户滤镜链，Win 反复重配 native af 滤镜图崩溃；当时改
/// `main.dart` 设 `JustAudioMediaKit.pitch = false` 修掉了**有声书**那条路。
///
/// 视频是另一条独立路径：它走 media_kit **裸 `Player()`**（不经 just_audio /
/// JustAudioMediaKit），所以 `JustAudioMediaKit.pitch=false` 那条修复**管不到视频**。
/// 视频调速是否安全，取决于 media_kit `PlayerConfiguration.pitch`：
///   - `pitch == true` → `setRate` 每次 `_setPropertyString('af', 'scaletempo:scale=…')`
///     重写 af 滤镜链（media_kit-1.2.6 `lib/src/player/native/player/real.dart`
///     `setRate` 的 `if (configuration.pitch)` 分支）→ 回归 TODO-070 调速闪退。
///   - `pitch == false`（media_kit 默认）→ 只 `_setPropertyDouble('speed', rate)`，
///     不动 af 链 → 安全。视频保音高靠 `load` 里一次性设的 `audio-pitch-correction=yes`
///     （[VideoMpvConfig] / `applyMpvConfigToPlayer`），与每次调速无关。
///
/// 故视频的 `Player()` **必须保持裸构造**（无 `PlayerConfiguration` / 不显式
/// `pitch: true`）。本守卫钉死这一点，防止有人为「保音高」把它改成
/// `Player(PlayerConfiguration(pitch: true))` 而在 Windows 上回归调速闪退。
/// 真实的图形/native 崩溃只能在 Windows 真机复测；此守卫锁住静态不变量。
void main() {
  String read(String relPath) {
    for (final String prefix in <String>['', '../']) {
      final File f = File('$prefix$relPath');
      if (f.existsSync()) return f.readAsStringSync();
    }
    throw StateError('找不到文件：$relPath');
  }

  group('视频调速不闪退不变量 (TODO-116)', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    test('VideoPlayerController 用裸 Player()（pitch 默认 false，不重写 af 滤镜图）', () {
      // load() 里实例化的就是裸 `Player()`；复用同一实例（换集不重建，BUG-120）。
      expect(src.contains('Player()'), isTrue,
          reason: '视频必须用裸 Player()（media_kit 默认 pitch=false 的安全调速路径）');
    });

    test('绝不用 PlayerConfiguration(pitch: true) 构造视频 Player（会回归 TODO-070 调速闪退）',
        () {
      // 容忍空白：匹配 `Player(` 后任意空白 + `PlayerConfiguration`。视频侧出现
      // 带 PlayerConfiguration 的 Player 构造即视为高危（默认安全路径是裸构造）。
      final bool hasConfiguredPlayer =
          RegExp(r'Player\(\s*PlayerConfiguration').hasMatch(src);
      expect(hasConfiguredPlayer, isFalse,
          reason: '视频 Player 不得带 PlayerConfiguration（尤其 pitch:true）——'
              'pitch:true 会让每次 setRate 重写 libmpv af 滤镜链，Win 回归调速闪退');
      // 退一步：即便将来引入 PlayerConfiguration，也绝不能开 pitch。
      expect(src.contains('pitch: true'), isFalse,
          reason: '视频侧不得出现 pitch: true（媒体管线音高补偿走 audio-pitch-correction）');
    });

    test('保留 setRate 安全性的根因说明注释（防止注释丢失后被误改）', () {
      expect(src.contains('audio-pitch-correction'), isTrue,
          reason: '视频保音高靠 audio-pitch-correction（不靠 media_kit pitch 配置）');
      // 注释里点名 TODO-116 与「pitch」契约，确保 reviewer 看到不变量来由。
      expect(
          src.contains('PlayerConfiguration.pitch') ||
              src.contains('configuration.pitch'),
          isTrue,
          reason: 'Player() 构造点必须保留 pitch 不变量的根因注释');
    });
  });

  group('依赖契约：media_kit setRate 按 configuration.pitch 分支 (TODO-116)', () {
    // 钉死我们依赖的 upstream 版本与行为：若 media_kit 升级改了 setRate 分支语义，
    // 本守卫与上面的不变量都需要重新核对（防止 upstream 漂移悄悄改变崩溃面）。
    test('pubspec.lock 仍钉在 media_kit 1.2.6（setRate 分支语义来源）', () {
      final String lock = read('pubspec.lock');
      // 精确锚到 `name: media_kit`（媒体内核包本体，非 media_kit_libs_* 等同前缀包），
      // 取该块后第一条 version。media_kit_libs_* 的 name 不等于 `media_kit`，不误命中。
      final int nameAt = lock.indexOf('name: media_kit\n');
      expect(nameAt, greaterThanOrEqualTo(0),
          reason: 'pubspec.lock 找不到 media_kit 包块');
      final RegExpMatch? m = RegExp(r'version:\s*"([0-9][^"]*)"')
          .firstMatch(lock.substring(nameAt));
      expect(m, isNotNull, reason: 'media_kit 包块内找不到 version');
      expect(m!.group(1), '1.2.6',
          reason: 'media_kit 版本变化时须重核 setRate 的 configuration.pitch 分支语义'
              '（本守卫与视频调速不变量基于 1.2.6 的行为）');
    });
  });
}
