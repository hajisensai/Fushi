import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 统一的系统分享入口（TODO-1318 / BUG-608）。
///
/// **根因**：`Share.shareXFiles` 走 share_plus 的**返回结果变体**
/// （platform interface 的 `shareFilesWithResult` 方法通道）。Android 侧
/// `ShareSuccessManager` 用一个原子标志 `isCalledBack` 串联「分享面板关闭」
/// 回调（`compareAndSet(true, false)`）。若上一次结果型分享的 `onActivityResult`
/// 没有回调（面板被系统方式关闭、Activity 因内存/旋转被重建、目标 App 未回传
/// 结果），该标志会**永久卡在 false**，之后**每一次** `shareXFiles` 都会抛
/// `PlatformException(Share callback error, prior share-sheet did not call
/// back, did you await it? Maybe use non-result variant, null, null)`；快速
/// 重复触发（连点分享按钮）同样命中这个分支。
///
/// **修复**：本 App 从不读取 `ShareResult`，因此统一改用**非结果变体**
/// （`Share.shareFiles`，`isWithResult=false`，从根上绕开 `ShareSuccessManager`
/// 整套回调状态机——它是错误的唯一来源），并叠加进程内**防重入**串行化，
/// 避免在面板呈现的瞬间被重复触发而堆叠两个分享面板。
class FushiShare {
  FushiShare._();

  // iOS 分享锚点（BUG-2064）：share_plus 的 iOS 端把 text / uri / files 三条
  // 路径统一汇进 `+share:`（`FPPSharePlusPlugin.m`）。只要
  // `popoverPresentationController != NULL`（iPad 必然成立，iPhone 横屏等场景
  // 也会成立），它就要求锚点 rect **非空**且被 root view 的 frame **完全包含**，
  // 否则直接抛 `PlatformException(error, sharePositionOrigin: argument must be
  // set, {{0, 0}, {0, 0}} must be non-zero and within coordinate space of
  // source view: ...)`——`sharePositionOrigin` 缺省时 rect 就是 `CGRectZero`。
  //
  // 因此锚点不是「调用方可选的美化项」，而是分享入口必须自带的**不变式**：
  // 由本类统一解析当前 view 的逻辑尺寸并给出居中的合法锚点，调用点不需要、
  // 也不应该各自传坐标（分散传参必然漏，漏一处就是一处崩溃）。
  // 非 iOS 平台的 share_plus 实现忽略该参数，无平台分支。

  /// 防重入：全 App 同一时刻只允许一个系统分享面板在途。
  static bool _sharing = false;

  /// 测试可见：当前是否有分享在途（仅供守卫断言，勿在业务逻辑读取）。
  static bool get debugIsSharing => _sharing;

  /// 由 [viewSize] 推出一个**必定合法**的 iOS popover 锚点：位于 view 正中、
  /// 边长 1 逻辑点的矩形。
  ///
  /// 不变式（对应 iOS 侧 `CGRectIsEmpty` + `CGRectContainsRect` 两道校验）：
  /// 返回的 rect 宽高恒 `> 0`，且恒被 `Offset.zero & viewSize` 完全包含。
  /// [viewSize] 非法（零、负、非有限）时退回 `1x1@(0,0)`——此时 view 本身还没
  /// 布局，任何锚点都不可能落在其坐标系内，给合法形状即可，不留 `CGRectZero`。
  @visibleForTesting
  static Rect sharePositionOriginForViewSize(Size viewSize) {
    final double vw = viewSize.width;
    final double vh = viewSize.height;
    if (!vw.isFinite || !vh.isFinite || vw <= 0 || vh <= 0) {
      return const Rect.fromLTWH(0, 0, 1, 1);
    }
    final double w = math.min(1, vw);
    final double h = math.min(1, vh);
    return Rect.fromLTWH((vw - w) / 2, (vh - h) / 2, w, h);
  }

  /// 当前 view 的逻辑尺寸。直接读 `dart:ui` 的 [ui.PlatformDispatcher]，不经
  /// `WidgetsBinding`：分享可能从没有 `BuildContext` 的平台 seam 触发。
  static Size _currentViewSize() {
    final ui.PlatformDispatcher dispatcher = ui.PlatformDispatcher.instance;
    final ui.FlutterView? view = dispatcher.implicitView ??
        (dispatcher.views.isNotEmpty ? dispatcher.views.first : null);
    if (view == null) return Size.zero;
    final double ratio = view.devicePixelRatio;
    if (!ratio.isFinite || ratio <= 0) return Size.zero;
    return view.physicalSize / ratio;
  }

  static Rect _sharePositionOrigin() =>
      sharePositionOriginForViewSize(_currentViewSize());

  /// 通过系统分享面板分享一段文本。
  ///
  /// 与 [shareFiles] 共用同一道防重入门（全 App 同一时刻只允许一个面板），并
  /// 同样自带 iOS 锚点。空文本直接返回：iOS 侧会以 `Non-empty text expected`
  /// 拒绝，Android 侧则弹出一个空面板，都不是有用行为。
  static Future<void> shareText(String text, {String? subject}) async {
    if (_sharing || text.isEmpty) return;
    _sharing = true;
    try {
      await Share.share(
        text,
        subject: subject,
        sharePositionOrigin: _sharePositionOrigin(),
      );
    } finally {
      _sharing = false;
    }
  }

  /// 通过系统分享面板分享一个或多个文件。
  ///
  /// [files] 允许包含内存型 `XFile`（`XFile.fromData`，`path` 为空）——会先落盘
  /// 到临时目录再分享，因为非结果分享通道只接受真实文件路径。
  ///
  /// 返回的 `Future` 在分享面板**呈现后**即完成（非结果变体不等待面板关闭），
  /// 不携带任何结果。重复触发（上一次尚未完成呈现）会被静默丢弃。
  static Future<void> shareFiles(
    List<XFile> files, {
    String? subject,
    String? text,
  }) async {
    if (_sharing || files.isEmpty) return;
    _sharing = true;
    try {
      final List<String> paths = <String>[];
      final List<String> mimeTypes = <String>[];
      Directory? tmpDir;
      for (final XFile file in files) {
        String path = file.path;
        if (path.isEmpty) {
          // 内存型 XFile：落盘到临时文件，供非结果分享通道读取。
          tmpDir ??= await getTemporaryDirectory();
          final String name = file.name.isNotEmpty
              ? file.name
              : 'fushi_share_${DateTime.now().microsecondsSinceEpoch}';
          path = p.join(tmpDir.path, name);
          await file.saveTo(path);
        }
        paths.add(path);
        // 显式 mime 优先；缺失时用 `*/*`（比 octet-stream 更宽，不会收窄
        // 可分享目标，属 shareXFiles 结果集的超集，无回归）。
        mimeTypes.add(file.mimeType ?? '*/*');
      }
      // 非结果变体：从根上绕开 `ShareSuccessManager` 的结果回调状态机
      // （TODO-1318）。本 App 不使用 `ShareResult`，故不再走
      // `shareXFiles` / `shareFilesWithResult`。
      // ignore: deprecated_member_use
      await Share.shareFiles(
        paths,
        mimeTypes: mimeTypes,
        subject: subject,
        text: text,
        sharePositionOrigin: _sharePositionOrigin(),
      );
    } finally {
      _sharing = false;
    }
  }
}
