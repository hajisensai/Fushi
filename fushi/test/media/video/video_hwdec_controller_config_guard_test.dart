import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';

/// 守卫（BUG-1545）：**`hwdec=auto` 绝不允许到达 libmpv**。
///
/// 背景（Windows + NVIDIA 整进程闪退，三份 minidump 栈完全一致）：
/// media_kit_video 的 `NativeVideoController.create` 把 `configuration.hwdec == null`
/// 兜底成 **`'auto'`**，并在建 `VideoController` 时立刻
/// `setProperties({'vo', 'hwdec', 'vid'})` 下发到 libmpv（vendored
/// `third_party/media_kit_video/lib/src/video_controller/native_video_controller/real.dart`）。
/// 而 `VideoPlayerController.load` 应用用户策略的 `applyMpvConfigToPlayer` 排在
/// `player.open` **之后**，于是首个文件的视频解码链是拿 `auto` 初始化的。
///
/// `auto` 是 mpv 的**全量**硬解列表，含非 copy 的 `cuda` / `nvdec`；而 [VideoMpvConfig]
/// 的合法值域只有 `{no, auto-safe, auto-copy}`，**从不允许 `auto`**。走到 CUDA 分支时
/// libmpv 在解码链初始化里调 `cuInit()` / `cuCtxCreate_v2()`，在 nvcuda64.dll 内部空指针
/// 解引用 → 进程 0xC0000005 闪退（无 Dart 异常，捕获不到，日志里只剩崩溃前的无关条目）。
///
/// 根因修复是给 `VideoController` **传 configuration**，让策略在第一次属性下发就生效，
/// 消除 `auto` 的时间窗本身。真实的驱动级崩溃只能在 Windows + NVIDIA 真机复测；
/// 本守卫锁住让它不可能再发生的静态/行为不变量。
void main() {
  String read(String relPath) {
    for (final String prefix in <String>['', '../']) {
      final File f = File('$prefix$relPath');
      if (f.existsSync()) return f.readAsStringSync();
    }
    throw StateError('找不到文件：$relPath');
  }

  group('hwdec 策略必须在 VideoController 构造时生效 (BUG-1545)', () {
    final String src = read('lib/src/media/video/video_player_controller.dart');

    test(
        'VideoController 必须带 configuration 构造（裸 VideoController(player) 会吃到 auto）',
        () {
      // 裸构造 = 不传 configuration → media_kit 兜底 'auto' → CUDA 崩溃路径。
      final bool hasBareController =
          RegExp(r'VideoController\(\s*player\s*[,)]\s*\n?\s*\)')
                  .hasMatch(src) ||
              RegExp(r'VideoController\(player\)').hasMatch(src);
      expect(hasBareController, isFalse,
          reason: '不得裸构造 VideoController(player)——media_kit 会把 hwdec 兜底成 '
              "'auto'（含 cuda/nvdec），Windows+NVIDIA 上 cuInit 空指针解引用整进程闪退");

      expect(src.contains('VideoControllerConfiguration('), isTrue,
          reason: 'VideoController 必须显式传 VideoControllerConfiguration');
    });

    test('configuration 的 hwdec 必须来自 app 策略（resolveAndroidHwdec + mpvConfig）',
        () {
      expect(
        RegExp(r'hwdec:\s*resolveAndroidHwdec\(\s*mpvConfig\.hwdec\s*\)')
            .hasMatch(src),
        isTrue,
        reason: 'hwdec 必须由本次 load 的 mpvConfig 经 resolveAndroidHwdec 解析，'
            '与 buildMpvProperties 取值一致（Android 仍为 copy 变体，BUG-465 不回归）',
      );
    });

    test('app 侧源码不得出现字面量 hwdec: \'auto\'（非 auto-safe / auto-copy）', () {
      // 只禁裸 'auto'；'auto-safe' / 'auto-copy' 合法，故用右边界断言。
      final bool hasBareAuto =
          RegExp("""hwdec['"]?\\s*[:=]\\s*['"]auto['"]""").hasMatch(src);
      expect(hasBareAuto, isFalse,
          reason: "video_player_controller 不得把 hwdec 硬编码成 'auto'");
    });

    test('vendored media_kit_video 仍把 hwdec 兜底成 auto（本守卫存在的前提）', () {
      final String vendored = read(
        '../third_party/media_kit_video/lib/src/video_controller/'
        'native_video_controller/real.dart',
      );
      expect(
        RegExp(r"hwdec:\s*configuration\.hwdec\s*\?\?\s*'auto'")
            .hasMatch(vendored),
        isTrue,
        reason: '若 vendored media_kit_video 改掉了这个兜底，请重新评估本守卫与 '
            'BUG-1545 的修复方式（前提变了，但传 configuration 仍是正确做法）',
      );
    });
  });

  group('VideoMpvConfig 值域不接受 auto (BUG-1545)', () {
    test("decode 把非法的 hwdec:'auto' 收敛回 auto-safe", () {
      final VideoMpvConfig cfg = VideoMpvConfig.decode('{"hwdec":"auto"}');
      expect(cfg.hwdec, 'auto-safe',
          reason: "'auto' 不在合法值域，必须回落默认 auto-safe，绝不能透传给 libmpv");
    });

    test('默认配置就是 auto-safe，不是 auto', () {
      expect(VideoMpvConfig.defaults.hwdec, 'auto-safe');
    });

    test('resolveAndroidHwdec 对任何合法值都不产出裸 auto', () {
      for (final String v in <String>['no', 'auto-safe', 'auto-copy']) {
        for (final bool android in <bool>[true, false]) {
          expect(resolveAndroidHwdec(v, isAndroid: android), isNot('auto'),
              reason: 'hwdec=$v (android=$android) 解析后不得是裸 auto');
        }
      }
    });

    test('Android 仍改写成 copy 变体（BUG-465 不回归）', () {
      expect(resolveAndroidHwdec('auto-safe', isAndroid: true), 'auto-copy');
      expect(resolveAndroidHwdec('auto-safe', isAndroid: false), 'auto-safe');
    });
  });
}
