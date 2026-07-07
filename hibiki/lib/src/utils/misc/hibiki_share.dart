import 'dart:async';
import 'dart:io';

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
class HibikiShare {
  HibikiShare._();

  /// 防重入：全 App 同一时刻只允许一个系统分享面板在途。
  static bool _sharing = false;

  /// 测试可见：当前是否有分享在途（仅供守卫断言，勿在业务逻辑读取）。
  static bool get debugIsSharing => _sharing;

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
              : 'hibiki_share_${DateTime.now().microsecondsSinceEpoch}';
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
      );
    } finally {
      _sharing = false;
    }
  }
}
