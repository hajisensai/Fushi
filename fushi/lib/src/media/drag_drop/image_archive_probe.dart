import 'dart:isolate';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/manga/manga_module.dart';

/// 「拖进来的这个 `.zip` 到底是图片型漫画包，还是 Yomitan 词典包」的预判，**跑在
/// 后台 isolate 上**。
///
/// 为什么必须挪出拖放回调：`MangaModule.isImageArchive` 会把整个压缩包**同步**解出
/// 目录（`.epub` 分支还会同步落一个临时解压树再解析 EPUB）。它原本直接长在
/// `classifyDroppedFiles` 的注入判据里，而那是 desktop_drop 回调的同步栈——拖一个
/// 几百 MB 的包进书架，UI 线程就在那儿卡住不画帧，用户看到的是「拖完 App 假死」。
/// 判据本身没问题（图片包与词典包同形，不真读包分不出来，见
/// [kDragImageArchiveProbeExtensions] 的说明），问题是它跑错了线程。
///
/// 结果先一次性算完再喂回 [classifyDroppedFiles] 的同步谓词，分类函数因此保持纯函数
/// 不变——不需要为了「判据变异步」把整条分类/决策链改成异步。
///
/// [probe] 是测试缝：默认走真实 isolate。注入后可在 widget 测试里同步返回，也可以
/// 让它抛出，验证失败路径（拖放不再静默消失）。
Future<Map<String, bool>> probeDroppedImageArchives(
  List<String> paths, {
  Future<bool> Function(String path)? probe,
}) async {
  final Future<bool> Function(String path) run = probe ?? _probeInIsolate;
  final Map<String, bool> results = <String, bool>{};
  for (final String path in paths) {
    if (!_needsProbe(path)) continue;
    if (results.containsKey(path)) continue;
    results[path] = await _neverThrows(path, run);
  }
  return results;
}

/// 判定本身**永不抛**：包损坏 / 没权限 / 超大都只是「这不是图片包」，让它落回按
/// 扩展名的常规分类（`.zip` → 词典包），而不是把整次拖放炸掉。
///
/// 包在这里而不是包在 [_probeInIsolate] 里：注入的测试探针也要走同一条容错路径，
/// 否则「生产吞、测试不吞」两套语义，守卫守的就不是真实行为。
Future<bool> _neverThrows(
  String path,
  Future<bool> Function(String path) run,
) async {
  try {
    return await run(path);
  } catch (error, stackTrace) {
    debugPrint('[fushi-drop] image archive probe failed for $path: $error\n'
        '$stackTrace');
    return false;
  }
}

/// 只有扩展名**确实二义**的才值得开包，与 [classifyDroppedFiles] 用同一份常量。
bool _needsProbe(String path) {
  final String extension = p.extension(path);
  if (extension.isEmpty) return false;
  return kDragImageArchiveProbeExtensions
      .contains(extension.substring(1).toLowerCase());
}

/// 单个包的真读包判定，跑在后台 isolate 上。容错在 [_neverThrows]。
Future<bool> _probeInIsolate(String path) =>
    Isolate.run(() => MangaModule.isImageArchive(path));
