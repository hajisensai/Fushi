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

    test('configuration 的 hwdec 必须来自 app 策略（resolvePlatformHwdec + mpvConfig）',
        () {
      expect(
        // BUG-2691：Android 远端 DV P5 片源经 _mpvConfigForCurrentSource 强制软解，
        // 包装后仍是本次 load 的 mpvConfig，两种形态都认。
        RegExp(r'hwdec:\s*resolvePlatformHwdec\(\s*'
                r'(?:mpvConfig|_mpvConfigForCurrentSource\(\s*mpvConfig\s*\))'
                r'\.hwdec\s*,?\s*\)')
            .hasMatch(src),
        isTrue,
        reason: 'hwdec 必须由本次 load 的 mpvConfig 经 resolvePlatformHwdec 解析，'
            '与 buildMpvProperties 取值一致（Android 仍为 copy 变体 BUG-465 不回归；'
            'Windows 为 D3D11 在前、CUDA 仅 copy 兜底的列表 BUG-1639/BUG-3315）',
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

    test('resolvePlatformHwdec 对任何合法值都不产出裸 auto', () {
      for (final String v in <String>['no', 'auto-safe', 'auto-copy']) {
        for (final bool android in <bool>[true, false]) {
          for (final bool windows in <bool>[true, false]) {
            expect(
                resolvePlatformHwdec(v, isAndroid: android, isWindows: windows),
                isNot('auto'),
                reason:
                    'hwdec=$v (android=$android, windows=$windows) 解析后不得是裸 auto');
          }
        }
      }
    });

    test('Android 仍改写成 copy 变体（BUG-465 不回归）', () {
      expect(
          resolvePlatformHwdec('auto-safe', isAndroid: true, isWindows: false),
          'auto-copy');
      expect(
          resolvePlatformHwdec('auto-safe', isAndroid: false, isWindows: false),
          'auto-safe');
    });
  });

  /// 守卫（BUG-1639）：**Windows 下发的 hwdec 值域里不得出现任何 CUDA 系后端**。
  ///
  /// BUG-1545 修掉了「media_kit 抢跑下发裸 `auto`」的时间窗，但把值换成用户策略
  /// `auto-safe` 之后崩溃复发——因为 `auto-safe` 的白名单里 `nvdec` 就是 CUDA API 的
  /// 封装。Windows 上 media_kit 同样走 GL(ANGLE) 纹理渲染，libmpv 拿不到宿主 D3D11
  /// device，`d3d11va` interop 在 hwdec 探测里必然 `Could not create device`，于是
  /// NVIDIA 机器必然回退 `nvdec` → `Loading hwdec driver 'cuda'` → `cuInit()` /
  /// `cuCtxCreate_v2()` → `nvcuda64.dll` 空指针 → 整进程 0xC0000005。
  ///
  /// 本机 libmpv 实测（GL 上下文 + 10-bit HEVC 片源）：
  /// `auto-safe` → `Using hardware decoding (nvdec)`（崩溃路径）；
  /// `d3d11va,d3d11va-copy` → `Using hardware decoding (d3d11va-copy)`（不碰 nvcuda64）。
  group(
    'Windows hwdec：零拷贝 CUDA 永不下发，CUDA 只以 copy 变体排在 D3D11 之后 (BUG-1639 / BUG-3315)',
    () {
      /// 非 copy 的 CUDA 后端：ANGLE 下零拷贝 interop 不可达，且是 BUG-1639 的崩溃入口。
      const List<String> zeroCopyCudaBackends = <String>['nvdec', 'cuda'];

      List<String> candidates(String value) =>
          value.split(',').map((String e) => e.trim()).toList();

      bool isCuda(String backend) =>
          backend.startsWith('nvdec') || backend.startsWith('cuda');

      test('任何合法 hwdec 在 Windows 解析后都不含零拷贝 nvdec / cuda', () {
        for (final String v in <String>['no', 'auto-safe', 'auto-copy']) {
          final List<String> resolved = candidates(
            resolvePlatformHwdec(v, isAndroid: false, isWindows: true),
          );
          for (final String backend in zeroCopyCudaBackends) {
            expect(
              resolved.contains(backend),
              isFalse,
              reason:
                  'hwdec=$v 在 Windows 解析成 $resolved，含零拷贝 CUDA 后端 '
                  '"$backend" → ANGLE 下不可达，且走 cuInit()/cuCtxCreate_v2() 崩溃路径',
            );
          }
        }
      });

      test('CUDA 候选只能是 copy 变体，且排在全部 D3D11 候选之后', () {
        for (final String value in <String>[
          kWindowsAutoHwdec,
          kWindowsCopyHwdec,
        ]) {
          final List<String> list = candidates(value);
          final int firstCuda = list.indexWhere(isCuda);
          final int lastD3d11 = list.lastIndexWhere(
            (String b) => b.startsWith('d3d11va'),
          );
          expect(
            lastD3d11,
            greaterThanOrEqualTo(0),
            reason: 'Windows 硬解首选 d3d11va（Win8+ 通用，Intel/AMD/NVIDIA 全支持）',
          );
          if (firstCuda < 0) continue;
          expect(
            firstCuda,
            greaterThan(lastD3d11),
            reason:
                '"$value"：CUDA 必须排在全部 D3D11 候选之后，D3D11 能解的格式'
                '（含 BUG-1639 的 HEVC Main 10）才不会加载 nvcuda64.dll',
          );
          for (final String b in list.where(isCuda)) {
            expect(
              b.endsWith('-copy'),
              isTrue,
              reason: '"$value" 里的 CUDA 候选 "$b" 必须是 copy 变体',
            );
          }
        }
      });

      test('H.264 High 10 有硬解路径：两档都以 nvdec-copy 兜底 (BUG-3315)', () {
        expect(
          candidates(kWindowsAutoHwdec).last,
          'nvdec-copy',
          reason: 'D3D11VA 没有 H.264 High 10 解码配置，不兜底就整条压到 CPU 软解',
        );
        expect(candidates(kWindowsCopyHwdec).last, 'nvdec-copy');
      });

      test('Windows 下 auto* 解析成显式候选表（保留两档语义差异）', () {
        expect(
          resolvePlatformHwdec('auto-safe', isAndroid: false, isWindows: true),
          kWindowsAutoHwdec,
          reason: 'auto-safe：先试 interop 直渲，失败静默回落 copy-back',
        );
        expect(
          resolvePlatformHwdec('auto-copy', isAndroid: false, isWindows: true),
          kWindowsCopyHwdec,
          reason: 'auto-copy：用户显式要 copy-back，只给 copy 变体',
        );
        for (final String b in candidates(kWindowsCopyHwdec)) {
          expect(
            b.endsWith('-copy'),
            isTrue,
            reason: 'auto-copy 档里不得出现非 copy 候选 "$b"',
          );
        }
      });

      test('Windows 下软解 no 原样透传（用户显式关硬解不被改写）', () {
      expect(
          resolvePlatformHwdec('no', isAndroid: false, isWindows: true), 'no');
    });

    test('非 Windows 桌面（macOS / Linux）原样透传，零行为变化', () {
      for (final String v in <String>['no', 'auto-safe', 'auto-copy']) {
        expect(resolvePlatformHwdec(v, isAndroid: false, isWindows: false), v,
            reason: '非 Android / 非 Windows 平台不改写 hwdec');
      }
    });

    test('buildMpvProperties 下发的 hwdec 在 Windows 同样不含零拷贝 CUDA', () {
        final Map<String, String> props = buildMpvProperties(
          VideoMpvConfig.defaults,
          isAndroid: false,
          isMobile: false,
          isWindows: true,
        );
        expect(
          props['hwdec'],
          kWindowsAutoHwdec,
          reason: 'controller 构造与 buildMpvProperties 两处取值必须恒一致',
        );
        for (final String backend in zeroCopyCudaBackends) {
          expect(candidates(props['hwdec']!).contains(backend), isFalse);
        }
      });
  });
}
