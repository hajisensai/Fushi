import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/utils.dart';
import 'package:path/path.dart' as p;

/// 「选一个文件夹并返回它的**真实文件系统绝对路径**」的统一入口。
///
/// 为什么不直接到处调 `FilePicker.getDirectoryPath()`：在安卓上 file_picker 的
/// `getDirectoryPath()` 走 SAF（`ACTION_OPEN_DOCUMENT_TREE`），返回的是 tree
/// content URI 解析出的字符串，对受保护目录还会退化成 `/` 或不可用路径。下游
/// `listVideoFilesInDirectory` / sidecar 扫描 / 封面 / 制卡 / 播放全是 `dart:io`
/// 真实路径语义，content URI 串喂进去恒空（TODO-949 的根因）。
///
/// 本 app 早已声明并请求 `MANAGE_EXTERNAL_STORAGE`（全文件访问），授予后
/// `dart:io Directory(realPath).listSync()` 在安卓全盘可读。所以安卓改为：
/// 先确保权限 → 弹一个基于 `dart:io` 的真实路径目录浏览器（根集来自
/// [AppModel.platformServices] 的 `getDefaultPickerDirectories()`）→ 返回真实
/// 绝对路径。**桌面 / iOS 维持 `getDirectoryPath()`**（它们本就返回真实路径）。
///
/// 这样把「安卓返回不可用串」这个特殊情况从下游消除：所有平台拿到的都是真实
/// 路径，videoPath / audioDir 的真实路径不变量在全平台一致。
Future<String?> pickRealDirectoryPath({
  required BuildContext context,
  required AppModel appModel,
}) async {
  // 桌面（Windows/macOS/Linux）与 iOS：`getDirectoryPath()` 已返回真实路径。
  if (defaultTargetPlatform != TargetPlatform.android) {
    return FilePicker.platform.getDirectoryPath();
  }

  // 安卓：先确保 MANAGE_EXTERNAL_STORAGE（全文件访问）已授权。
  await appModel.requestExternalStoragePermissions();
  final bool granted =
      await appModel.platformServices.permission.hasExternalStoragePermission();
  if (!granted) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.folder_picker_permission_required)),
      );
    }
    return null;
  }

  final List<String> roots =
      await appModel.platformServices.directory.getDefaultPickerDirectories();
  if (!context.mounted) return null;

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext sheetContext) =>
        _RealPathDirectoryBrowser(roots: roots),
  );
}

/// 列出 [directory] 的直接子目录绝对路径（已排序，目录不存在或无权限时返回空）。
///
/// 纯函数（仅碰磁盘，不碰 UI），抽出便于单测。`listSync` 对无法访问的目录会抛
/// [FileSystemException]，整体兜底成空列表而非崩溃（与
/// `listVideoFilesInDirectory` 的「逐项跳过」容错哲学一致）。
List<String> listSubdirectories(String directory) {
  final Directory dir = Directory(directory);
  if (!dir.existsSync()) return const <String>[];
  final List<String> out = <String>[];
  try {
    for (final FileSystemEntity entity
        in dir.listSync(recursive: false, followLinks: false)) {
      if (entity is Directory) out.add(entity.path);
    }
  } on FileSystemException {
    return const <String>[];
  }
  out.sort();
  return out;
}

/// 真实路径目录浏览器：从外置存储根集开始逐级下钻，pop 回选中的真实绝对路径。
class _RealPathDirectoryBrowser extends StatefulWidget {
  const _RealPathDirectoryBrowser({required this.roots});

  /// 起始根目录集（安卓外置存储根，真实绝对路径）。
  final List<String> roots;

  @override
  State<_RealPathDirectoryBrowser> createState() =>
      _RealPathDirectoryBrowserState();
}

class _RealPathDirectoryBrowserState extends State<_RealPathDirectoryBrowser> {
  /// 当前浏览的目录；null = 停在根集列表（多根时让用户先选一个根）。
  String? _current;

  /// 当前 [_current] 是否就是某个根（用于决定「上一级」是回根集还是回父目录）。
  bool get _atRootList => _current == null;

  bool _isRoot(String path) =>
      widget.roots.any((String r) => p.equals(r, path));

  void _enter(String path) => setState(() => _current = path);

  void _goUp() {
    final String? cur = _current;
    if (cur == null) return;
    if (_isRoot(cur)) {
      setState(() => _current = null);
      return;
    }
    final String parent = p.dirname(cur);
    setState(() => _current = parent);
  }

  @override
  Widget build(BuildContext context) {
    final String? cur = _current;
    final List<String> entries =
        _atRootList ? widget.roots : listSubdirectories(cur!);

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (BuildContext context, ScrollController scrollController) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                leading: _atRootList
                    ? const Icon(Icons.folder_open)
                    : IconButton(
                        icon: const Icon(Icons.arrow_back),
                        tooltip: t.folder_picker_up,
                        onPressed: _goUp,
                      ),
                title: Text(
                  _atRootList
                      ? t.folder_picker_title
                      : p.basename(cur!).isEmpty
                          ? cur
                          : p.basename(cur),
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: _atRootList ? null : Text(cur!, maxLines: 1),
                trailing: _atRootList
                    ? null
                    : FilledButton(
                        onPressed: () => Navigator.pop(context, cur),
                        child: Text(t.folder_picker_select),
                      ),
              ),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? Center(child: Text(t.folder_picker_empty))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: entries.length,
                        itemBuilder: (BuildContext context, int index) {
                          final String path = entries[index];
                          return ListTile(
                            leading: const Icon(Icons.folder),
                            title: Text(
                              p.basename(path).isEmpty
                                  ? path
                                  : p.basename(path),
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _enter(path),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
