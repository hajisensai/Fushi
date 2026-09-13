import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_backing_render_size.dart';

import '../../helpers/source_guard.dart';

/// 用户报告「mac 视频发虚」，指定按 IINA 的做法修。
///
/// 根因：media_kit 在 darwin 上把纹理固定建成**视频原生分辨率**，缩放由 Flutter 用
/// `FilterQuality.low`（双线性）做。Retina 屏的物理像素是逻辑尺寸的 2 倍，于是
/// 1080p 片源在 1440×810pt 的框里每帧都被从 1920 拉到 2880 物理像素——发虚，且 mpv
/// 的缩放器 / 用户着色器完全用不上（缩放不在 mpv 里发生）。IINA 让 mpv 直接渲染到
/// backing store 尺寸；本仓的落点是 `VideoBackingRenderSize` + `setSize`。
///
/// 真实渲染要 macOS + NSWindow + 平台通道，headless 一样都没有，所以数值契约落在纯
/// 函数上（下面第一组），接线落在源码守卫上（第二组）。
void main() {
  const Size hd = Size(1920, 1080);

  group('resolveVideoBackingRenderSize（渲染尺寸契约）', () {
    test('Retina contain：按画面实际占用的物理像素渲染（IINA 同款）', () {
      // 1440×810pt 的框、DPR 2 ⇒ 2880×1620 物理像素；片源比例与框一致 ⇒ 满铺。
      final Size? size = resolveVideoBackingRenderSize(
        boxLogicalSize: const Size(1440, 810),
        devicePixelRatio: 2,
        videoNativeSize: hd,
        fit: BoxFit.contain,
      );
      expect(size, const Size(2880, 1620));
    });

    test('比例不等的框：contain 取内接边，绝不按框的比例拉伸', () {
      // 2000×1000pt @DPR2 = 4000×2000 物理；16:9 片源内接后由高度决定 ⇒ ×2000/1080。
      final Size? size = resolveVideoBackingRenderSize(
        boxLogicalSize: const Size(2000, 1000),
        devicePixelRatio: 2,
        videoNativeSize: hd,
        fit: BoxFit.contain,
        maxPixels: double.infinity,
      );
      expect(size, isNotNull);
      // 必须保持片源宽高比：mpv 会在给定尺寸里自己保持比例并补黑边，比例一旦不对，
      // 黑边就被烤进纹理，Flutter 侧的 cover / fill 会连黑边一起裁 / 拉。
      expect(size!.width / size.height, closeTo(hd.width / hd.height, 0.01));
      expect(size.height, closeTo(2000, 2));
    });

    test('cover / fill 取外接边（欠采样的那一维才是被放大的那一维）', () {
      final Size? cover = resolveVideoBackingRenderSize(
        boxLogicalSize: const Size(2000, 1000),
        devicePixelRatio: 2,
        videoNativeSize: hd,
        fit: BoxFit.cover,
        maxPixels: double.infinity,
      );
      expect(cover, isNotNull);
      expect(cover!.width, closeTo(4000, 2));
      expect(cover.width / cover.height, closeTo(hd.width / hd.height, 0.01));

      final Size? fill = resolveVideoBackingRenderSize(
        boxLogicalSize: const Size(2000, 1000),
        devicePixelRatio: 2,
        videoNativeSize: hd,
        fit: BoxFit.fill,
        maxPixels: double.infinity,
      );
      expect(fill, cover, reason: 'fill 由 Flutter 拉伸，像素量需求与 cover 同档');
    });

    test('非 Retina 且尺寸接近原生：不下发（保持 media_kit 默认路径）', () {
      expect(
        resolveVideoBackingRenderSize(
          boxLogicalSize: const Size(1920, 1080),
          devicePixelRatio: 1,
          videoNativeSize: hd,
          fit: BoxFit.contain,
        ),
        isNull,
      );
      // ±5% 以内同样不动（拖窗口一点点就重建纹理不划算）。
      expect(
        resolveVideoBackingRenderSize(
          boxLogicalSize: const Size(1960, 1102),
          devicePixelRatio: 1,
          videoNativeSize: hd,
          fit: BoxFit.contain,
        ),
        isNull,
      );
    });

    test('缩小也要下发：4K 片源塞进小窗口，交给 mpv 降采样', () {
      final Size? size = resolveVideoBackingRenderSize(
        boxLogicalSize: const Size(640, 360),
        devicePixelRatio: 2,
        videoNativeSize: const Size(3840, 2160),
        fit: BoxFit.contain,
      );
      expect(size, const Size(1280, 720));
    });

    test('像素上限：软件渲染路径不能被 6K 全屏放大吃满 CPU', () {
      final Size? size = resolveVideoBackingRenderSize(
        boxLogicalSize: const Size(3008, 1692),
        devicePixelRatio: 2,
        videoNativeSize: hd,
        fit: BoxFit.contain,
      );
      expect(size, isNotNull);
      expect(
        size!.width * size.height,
        lessThanOrEqualTo(kVideoBackingRenderMaxPixels),
      );
      expect(size.width / size.height, closeTo(hd.width / hd.height, 0.01));
    });

    test('首帧出画前 / 退化输入：一律不下发', () {
      expect(
        resolveVideoBackingRenderSize(
          boxLogicalSize: const Size(1440, 810),
          devicePixelRatio: 2,
          videoNativeSize: null,
          fit: BoxFit.contain,
        ),
        isNull,
      );
      expect(
        resolveVideoBackingRenderSize(
          boxLogicalSize: Size.infinite,
          devicePixelRatio: 2,
          videoNativeSize: hd,
          fit: BoxFit.contain,
        ),
        isNull,
        reason: '无界约束（infinite）算出来的尺寸没有意义',
      );
      expect(
        resolveVideoBackingRenderSize(
          boxLogicalSize: Size.zero,
          devicePixelRatio: 2,
          videoNativeSize: hd,
          fit: BoxFit.contain,
        ),
        isNull,
      );
    });

    test('videoNativeSizeOf：只认解出画的正尺寸', () {
      expect(videoNativeSizeOf(1920, 1080), const Size(1920, 1080));
      expect(videoNativeSizeOf(null, 1080), isNull);
      expect(videoNativeSizeOf(1920, null), isNull);
      expect(videoNativeSizeOf(0, 0), isNull);
    });
  });

  group('接线', () {
    final String helper = maskComments(
      File(
        'lib/src/media/video/video_backing_render_size.dart',
      ).readAsStringSync(),
    );
    final String layout = maskComments(
      File(
        'lib/src/pages/implementations/video_fushi/layout.part.dart',
      ).readAsStringSync(),
    );
    final String fullscreen = maskComments(
      File(
        'lib/src/pages/implementations/video_fushi/fullscreen.part.dart',
      ).readAsStringSync(),
    );

    test('窗口与全屏两条 Video 都接上（全屏才是放得最大的那条）', () {
      expect(layout, contains('VideoBackingRenderSize('));
      expect(fullscreen, contains('VideoBackingRenderSize('));
    });

    test('尺寸输入取原生解码尺寸，不取 controller.rect（否则自激）', () {
      expect(helper, contains('videoNativeSizeOf('));
      expect(
        helper,
        isNot(contains('controller.rect')),
        reason: 'rect 正是本组件写进去的值，拿它当输入会「下发→rect 变→再下发」',
      );
      for (final String source in <String>[layout, fullscreen]) {
        expect(source, contains('videoNativeSizeOf('));
        expect(
          source,
          contains('videoFitModeToBoxFit(_videoFitMode)'),
          reason: '渲染尺寸必须跟随用户的画面比例偏好，否则 cover 下欠采样',
        );
      }
    });

    test('只在 macOS 生效，且尺寸变化经防抖', () {
      expect(
        helper,
        contains('Platform.isMacOS'),
        reason: 'Windows 走 ANGLE + HDR 宿主窗另一条链路，不在本次范围',
      );
      expect(helper, contains('Timer('), reason: '拖窗口会连发几十帧不同尺寸，不防抖就是每帧重建纹理');
      expect(helper, contains('setSize('));
    });
  });
}
