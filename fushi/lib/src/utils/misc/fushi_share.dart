import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// 系统分享面板**呈现**的上限。
///
/// 非结果变体的 Future 在面板呈现后即完成（不等关闭），所以这是一次「把面板画
/// 出来」的往返，正常在几百毫秒内；留 30 s 是给冷启动的分享目标枚举留余量。
/// 不加这道上限时，平台侧不回包就会把 [FushiShare._sharing] 永久钉在 true——
/// 那是个 static 字段，一坏就是**全 App** 此后每一次分享都被防重入门静默丢弃
/// （BUG-2542）。
const Duration _kSharePresentationTimeout = Duration(seconds: 30);

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
  //
  // 平台消费面（BUG-2064 复核实测，别照抄「只有 iOS 读锚点」）：
  // - iOS：见上，缺锚点在 iPad / iPhone 横屏必崩，这是本参数存在的理由。
  // - macOS：**同样消费**。`SharePlusMacosPlugin.originRect()` 在缺参时取
  //   `NSMakeRect(0,0,0,0)`，再交给 `picker.show(relativeTo:of:preferredEdge:)`；
  //   AppKit 约定空 rect 退化成 view 的 bounds。所以统一改传居中 1×1 锚点之后，
  //   macOS 分享面板的落点会从窗口边沿移到**窗口正中**；iPad popover 的箭头同理
  //   指向屏幕正中，而不是触发分享的那个按钮。拿这点观感换掉 iOS 上的必崩，是
  //   有意的取舍——锚点的合法性是硬约束，落点只是美观。
  // - Android / Windows / Linux：确实忽略该参数（`MethodCallHandler.kt`、
  //   `share_plus_plugin.cpp`、`share_plus_linux.dart` 都不读它）。
  // 因此仍然不需要平台分支：给出一个恒合法的锚点，五个平台都能正确处理。

  /// 防重入：全 App 同一时刻只允许一个系统分享面板在途。
  static bool _sharing = false;

  /// 测试可见：当前是否有分享在途（仅供守卫断言，勿在业务逻辑读取）。
  static bool get debugIsSharing => _sharing;

  /// 宿主没有系统**文件**分享面板时「把文件交给用户」的通道；null = 走系统
  /// 分享面板。
  ///
  /// share_plus 的 Linux 端只会把文本拼成 `mailto:` 链接，文件分享直接抛
  /// `UnimplementedError`（`share_plus_linux.dart`）——桌面 Linux 没有系统分享
  /// 面板这个契约。导出类调用方要的只是「让用户拿到这个文件」，所以那里改为在
  /// 文件管理器里定位它（与书架「打开文件位置」同一条原语）。
  ///
  /// 平台判据只在这里读一次；测试据此显式固定走哪条通道，而不是让断言随宿主
  /// 操作系统漂移（Linux CI 上跑 share 通道断言曾因此整组变红）。
  @visibleForTesting
  static Future<bool> Function(String path)? fileHandoffWithoutShareSheet =
      Platform.isLinux ? revealInFileManager : null;

  /// Android 文件分享的**快照根目录**来源；null = 不走 Android 自有通道（其余平台
  /// 仍交给 share_plus）。
  ///
  /// **为什么 Android 不走 share_plus（BUG-4740，反馈 P1pyoS0dQb）**：share_plus
  /// 7.2.2 的 Android 端在 MethodChannel 回调里（Android 主线程）对每个文件无条件
  /// `File.copyTo(cache/share_plus/…)` 整份同步拷贝；分享几百 MB 的片段 / m4b /
  /// 备份时主线程卡在 `FileOutputStream.write`，系统判 ANR。拷贝本身不能省——调用方
  /// 分享后会删临时产物（如反馈录屏的临时目录），接收方读的必须是独立快照——所以
  /// 把它挪到这里用异步 I/O 做（[stageFilesForShare]），原生侧
  /// `FushiShareChannel.kt` 只拼 Intent、不碰文件内容。
  ///
  /// 平台判据只在这里读一次；测试据此显式固定走哪条通道并给出临时目录。
  @visibleForTesting
  static Future<Directory> Function()? androidShareStagingRoot =
      Platform.isAndroid ? _defaultAndroidShareStagingRoot : null;

  /// `getTemporaryDirectory()` 在 Android 上是 cacheDir，被 `provider_paths.xml`
  /// 的 `cache-path` 覆盖，`FushiFileProvider` 能直接给出 `content://` URI。
  static Future<Directory> _defaultAndroidShareStagingRoot() async =>
      Directory(p.join((await getTemporaryDirectory()).path, 'fushi_share'));

  /// 把 [files] 落成一份分享快照，返回快照路径（与 [files] 同序）。
  ///
  /// - 全部用异步文件 I/O（Dart IO 线程），不占 Android 主线程，也不阻塞 UI isolate。
  /// - [root] 下只保留**本次**分享：先清掉上一次的快照（与 share_plus 每次分享先清
  ///   `cache/share_plus` 同一语义，避免缓存无限增长）。
  /// - 每个文件独占一个序号子目录，保留原文件名（接收方看到的文件名不变），同名
  ///   文件互不覆盖。
  /// - 内存型 `XFile`（`path` 为空）直接写进快照目录，不再先落一次临时文件。
  /// - 源文件位于 [root] 里时抛 [ArgumentError]：清旧快照会把它删掉。
  @visibleForTesting
  static Future<List<String>> stageFilesForShare(
    List<XFile> files,
    Directory root,
  ) async {
    final String rootPath = p.normalize(p.absolute(root.path));
    for (final XFile file in files) {
      if (file.path.isNotEmpty &&
          p.isWithin(rootPath, p.normalize(p.absolute(file.path)))) {
        throw ArgumentError.value(
          file.path,
          'files',
          'must not live inside the share staging directory $rootPath',
        );
      }
    }
    final Directory rootDir = Directory(rootPath);
    if (await rootDir.exists()) await rootDir.delete(recursive: true);
    final Directory shareDir = await Directory(
      p.join(rootPath, '${DateTime.now().microsecondsSinceEpoch}'),
    ).create(recursive: true);
    final List<String> staged = <String>[];
    for (int i = 0; i < files.length; i++) {
      final XFile file = files[i];
      // 有路径的文件用 `p.basename` 取名：XFile.name 只按宿主分隔符切，混用 `/`
      // 与 `\` 的路径会把目录段带进文件名，落到不存在的子目录里。
      final String base = file.path.isNotEmpty
          ? p.basename(file.path)
          : file.name;
      final String name = base.isNotEmpty ? base : 'fushi_share_$i';
      final Directory slot = await Directory(
        p.join(shareDir.path, '$i'),
      ).create();
      final String dest = p.join(slot.path, name);
      await file.saveTo(dest);
      staged.add(dest);
    }
    return staged;
  }

  /// 多个文件的 MIME 归并成 Intent 的一个 `type`（同 share_plus
  /// `Share.reduceMimeTypes`）：全相同取原值，同主类型取 `主类型/*`，否则 `*/*`。
  @visibleForTesting
  static String reduceShareMimeTypes(List<String> mimeTypes) {
    if (mimeTypes.isEmpty) return '*/*';
    String common = mimeTypes.first;
    for (int i = 1; i < mimeTypes.length; i++) {
      if (common == mimeTypes[i]) continue;
      final String base = _mimeTypeBase(mimeTypes[i]);
      if (_mimeTypeBase(common) == base) {
        common = '$base/*';
      } else {
        return '*/*';
      }
    }
    return common;
  }

  static String _mimeTypeBase(String mimeType) {
    final int slash = mimeType.indexOf('/');
    return slash < 0 ? '*' : mimeType.substring(0, slash);
  }

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
    final ui.FlutterView? view =
        dispatcher.implicitView ??
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
  ///
  /// 返回**面板是否真的呈现出来了**——语义与 [shareFiles] 一致，见那里的说明。
  static Future<bool> shareText(String text, {String? subject}) async {
    if (_sharing || text.isEmpty) {
      _logDroppedShare('shareText', reentrant: _sharing);
      return false;
    }
    _sharing = true;
    try {
      await Share.share(
        text,
        subject: subject,
        sharePositionOrigin: _sharePositionOrigin(),
      ).timeout(_kSharePresentationTimeout);
      return true;
    } on TimeoutException {
      _logShareTimeout('shareText');
      return false;
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
  /// 其值是**面板是否真的呈现出来了**：`false` 表示这次分享根本没送出去——被
  /// 防重入门丢弃、文件列表为空，或平台侧在 [_kSharePresentationTimeout] 内没
  /// 回包。`true` 不代表用户完成了分享（非结果变体拿不到这个），只代表面板已
  /// 呈现。
  ///
  /// **为什么必须有返回值（BUG-2542）**：手机端的片段导出、备份导出、日志导出
  /// 把产物落在 app 私有目录（不进相册、不注册 MediaStore），这次系统分享面板
  /// 是用户取回文件的**唯一**通道。旧签名是 `Future<void>`，被丢弃时静默返回，
  /// 调用方无从得知，于是照样弹「已保存」成功提示——面板没出现、相册里没有、
  /// 私有目录用户进不去，文件等于凭空消失。调用方现在据此决定报成功还是报失败。
  static Future<bool> shareFiles(
    List<XFile> files, {
    String? subject,
    String? text,
  }) async {
    if (_sharing || files.isEmpty) {
      _logDroppedShare('shareFiles', reentrant: _sharing);
      return false;
    }
    _sharing = true;
    try {
      final Future<Directory> Function()? stagingRoot = androidShareStagingRoot;
      if (stagingRoot != null) {
        // Android：快照用异步 I/O 落好，原生侧只拼 Intent（BUG-4740）。快照耗时
        // 不计入呈现上限——几百 MB 的拷贝本来就可能超过 30 s，那不是「平台没回包」。
        final List<String> staged = await stageFilesForShare(
          files,
          await stagingRoot(),
        );
        await FushiChannels.share
            .invokeMethod<void>('shareFiles', <String, Object?>{
              'paths': staged,
              'mimeType': reduceShareMimeTypes(<String>[
                for (final XFile file in files) file.mimeType ?? '*/*',
              ]),
              'text': text,
              'subject': subject,
            })
            .timeout(_kSharePresentationTimeout);
        return true;
      }
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
      final Future<bool> Function(String path)? handoff =
          fileHandoffWithoutShareSheet;
      if (handoff != null) {
        // 无文件分享面板的宿主（Linux）：在文件管理器里定位产物，返回值语义
        // 不变——文件管理器拉起来了就是 true。见 [fileHandoffWithoutShareSheet]。
        return await handoff(paths.first);
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
      ).timeout(_kSharePresentationTimeout);
      return true;
    } on TimeoutException {
      _logShareTimeout('shareFiles');
      return false;
    } finally {
      _sharing = false;
    }
  }

  /// 分享被防重入门丢弃时留一条可查的记录。
  ///
  /// 这条出口从前是裸 `return`，用户报「导出了但什么都没发生」时错误日志页一片
  /// 空白，无从判断是导出失败还是分享被丢弃（BUG-2542）。
  ///
  /// **只记重入**：空输入（`files.isEmpty` / `text.isEmpty`）是调用方自己的空
  /// 调用，没有用户意图被丢掉，记成用户可见「错误」只是噪声（还会顶高日志页的
  /// 错误计数）；重入丢弃才是真把用户要的东西扔了。
  static void _logDroppedShare(String entry, {required bool reentrant}) {
    if (!reentrant) return;
    ErrorLogService.instance.log(
      'FushiShare.$entry',
      'share dropped before reaching the platform: '
          'another share sheet is still being presented',
      StackTrace.current,
    );
  }

  /// 平台侧在呈现上限内没回包。记下来，并让调用方拿到 `false`。
  static void _logShareTimeout(String entry) {
    ErrorLogService.instance.log(
      'FushiShare.$entry',
      'share sheet did not present within $_kSharePresentationTimeout; '
          'the reentrancy gate has been released so later shares still work',
      StackTrace.current,
    );
  }
}
