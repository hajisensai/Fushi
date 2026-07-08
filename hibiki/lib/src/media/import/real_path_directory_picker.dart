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
    builder: (BuildContext sheetContext) => _RealPathBrowser(
      roots: roots,
      mode: _BrowserMode.directory,
      allowedExtensions: null,
    ),
  );
}

/// 「选一个**文件**并返回它的真实文件系统绝对路径」的统一入口（board 1112）。
///
/// 与 [pickRealDirectoryPath] 同源同哲学，只是叶子是文件而非目录：安卓上
/// `FilePicker.pickFiles()` 走 SAF，会把选中文件**复制一份到 app cache** 再返回
/// 缓存路径——手机存储/IO 差时白拷一份大视频，且清缓存后该路径失效、videoPath 引用
/// 悬空。视频/字幕导入本就只存绝对路径不复制（见 video_import_dialog），这个缓存副本
/// 是唯一残留的「变相复制」。
///
/// 授予 `MANAGE_EXTERNAL_STORAGE`（全文件访问）后，`dart:io` 可全盘读真实路径，于是
/// 安卓改为：先确保权限 → 弹真实路径浏览器（下钻目录、点文件返回其绝对路径，可按
/// [allowedExtensions] 过滤，如字幕 srt/ass/vtt）→ 返回真实绝对路径，不产生任何副本。
///
/// **降级逃生口**：安卓未授予全文件访问时，回退到 `FilePicker.pickFiles()`（仍复制到
/// cache，但功能可用）——不硬性要求授权。**桌面 / iOS 维持 `pickFiles()`**（它们本就
/// 返回真实路径、不复制）。
///
/// [allowedExtensions] 为不带点的小写扩展名集（如 `{'srt','ass'}`）；null = 不过滤
/// （任意文件，用于视频，避免维护两份视频扩展名清单）。传给回退的 `pickFiles` 时
/// 会转成其 `allowedExtensions` 语义（custom 类型）。
Future<String?> pickRealFilePath({
  required BuildContext context,
  required AppModel appModel,
  Set<String>? allowedExtensions,
}) async {
  // 桌面（Windows/macOS/Linux）与 iOS：`pickFiles()` 已返回真实路径、不复制。
  if (defaultTargetPlatform != TargetPlatform.android) {
    return _fallbackPickFile(
      context: context,
      allowedExtensions: allowedExtensions,
    );
  }

  // 安卓：先尝试确保 MANAGE_EXTERNAL_STORAGE（全文件访问）已授权。
  await appModel.requestExternalStoragePermissions();
  final bool granted =
      await appModel.platformServices.permission.hasExternalStoragePermission();
  if (!granted) {
    // 降级逃生口：无全文件访问权限时回退 file_picker（仍复制到 cache 但可用）。
    if (!context.mounted) return null;
    return _fallbackPickFile(
      context: context,
      allowedExtensions: allowedExtensions,
    );
  }

  final List<String> roots =
      await appModel.platformServices.directory.getDefaultPickerDirectories();
  if (!context.mounted) return null;

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext sheetContext) => _RealPathBrowser(
      roots: roots,
      mode: _BrowserMode.file,
      allowedExtensions: allowedExtensions,
    ),
  );
}

/// 「选多个文件并返回真实文件系统绝对路径」。
///
/// 当前真实路径浏览器只支持单文件点选；多选仍回退到 file_picker。iOS 上不能使用
/// file_picker 的 audio 类型，它会打开 `MPMediaPickerController`（资料库）而不是 Files；
/// 带扩展名过滤的入口统一由 [_fallbackPickFiles] 处理。
Future<List<String>> pickRealFilePaths({
  required BuildContext context,
  required AppModel appModel,
  Set<String>? allowedExtensions,
}) async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    await appModel.requestExternalStoragePermissions();
  }
  if (!context.mounted) return const <String>[];
  return _fallbackPickFiles(
    context: context,
    allowedExtensions: allowedExtensions,
    allowMultiple: true,
  );
}

/// 回退到 file_picker 选单个文件（安卓无全文件访问 / 桌面 / iOS）。
Future<String?> _fallbackPickFile({
  required BuildContext context,
  Set<String>? allowedExtensions,
}) async {
  final List<String> paths = await _fallbackPickFiles(
    context: context,
    allowedExtensions: allowedExtensions,
    allowMultiple: false,
  );
  return paths.isEmpty ? null : paths.single;
}

/// 回退到 file_picker 选文件。iOS 对 `.srt` 等扩展名的 UTI 解析可能返回 dyn.*，
/// 传给 `FileType.custom` 后会被原生插件丢弃；因此 iOS 先用 `FileType.any`
/// 打开 Files，再按扩展名做 Dart 端校验。
Future<List<String>> _fallbackPickFiles({
  required BuildContext context,
  required bool allowMultiple,
  Set<String>? allowedExtensions,
}) async {
  final Set<String> normalizedExtensions =
      _normalizeExtensions(allowedExtensions);
  final bool filterAfterPick = defaultTargetPlatform == TargetPlatform.iOS &&
      normalizedExtensions.isNotEmpty;

  final FilePickerResult? result;
  if (filterAfterPick || normalizedExtensions.isEmpty) {
    result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: allowMultiple,
    );
  } else {
    result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: normalizedExtensions.toList(),
      allowMultiple: allowMultiple,
    );
  }

  final List<String> paths =
      result?.files.map((file) => file.path).whereType<String>().toList() ??
          const <String>[];
  if (!filterAfterPick) return paths;

  // 页面若在原生文件选择器打开期间被销毁，仍按扩展名做纯过滤返回，只是无法
  // 弹「不支持格式」提示（context 传 null，过滤逻辑不依赖 context）。
  if (!context.mounted) {
    return _filterPickedFilesByExtension(
      context: null,
      paths: paths,
      allowedExtensions: normalizedExtensions,
    );
  }
  return _filterPickedFilesByExtension(
    context: context,
    paths: paths,
    allowedExtensions: normalizedExtensions,
  );
}

Set<String> _normalizeExtensions(Set<String>? extensions) {
  if (extensions == null || extensions.isEmpty) return const <String>{};
  return extensions
      .map((String ext) => ext.toLowerCase().replaceFirst('.', ''))
      .where((String ext) => ext.isNotEmpty)
      .toSet();
}

List<String> _filterPickedFilesByExtension({
  required BuildContext? context,
  required List<String> paths,
  required Set<String> allowedExtensions,
}) {
  final List<String> accepted = <String>[];
  final List<String> rejected = <String>[];
  for (final String path in paths) {
    final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    if (allowedExtensions.contains(ext)) {
      accepted.add(path);
    } else {
      rejected.add(path);
    }
  }
  if (rejected.isNotEmpty && context != null && context.mounted) {
    final String ext = p.extension(rejected.first).toLowerCase();
    HibikiToast.show(
      msg: t.import_unsupported_file_format(
        ext: ext.isEmpty ? p.basename(rejected.first) : ext,
      ),
    );
  }
  return accepted;
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

/// 列出 [directory] 直接子文件的绝对路径（已排序）；[allowedExtensions] 非空时
/// 只保留扩展名（不带点、小写）命中的文件，null = 不过滤。
///
/// 纯函数（仅碰磁盘，不碰 UI），供文件选择浏览器列叶子文件。容错哲学同
/// [listSubdirectories]：目录不存在 / 无权限 → 空列表而非崩溃。
List<String> listFilesInDirectory(
  String directory, {
  Set<String>? allowedExtensions,
}) {
  final Directory dir = Directory(directory);
  if (!dir.existsSync()) return const <String>[];
  final List<String> out = <String>[];
  try {
    for (final FileSystemEntity entity
        in dir.listSync(recursive: false, followLinks: false)) {
      if (entity is! File) continue;
      if (allowedExtensions == null || allowedExtensions.isEmpty) {
        out.add(entity.path);
        continue;
      }
      final String ext =
          p.extension(entity.path).replaceFirst('.', '').toLowerCase();
      if (allowedExtensions.contains(ext)) out.add(entity.path);
    }
  } on FileSystemException {
    return const <String>[];
  }
  out.sort();
  return out;
}

/// 浏览器叶子选择模式：选目录本身，还是下钻到文件选一个文件。
enum _BrowserMode { directory, file }

/// 真实路径浏览器：从外置存储根集开始逐级下钻，pop 回选中的真实绝对路径。
///
/// 两种模式共用同一下钻 UI：
/// - [_BrowserMode.directory]（[pickRealDirectoryPath]）：header 顶部有「选择此
///   文件夹」按钮，列表只列子目录，点目录下钻。
/// - [_BrowserMode.file]（[pickRealFilePath]）：列表同时列子目录（点击下钻）与
///   文件（点击直接 pop 回其绝对路径），无「选择此文件夹」按钮；[allowedExtensions]
///   非空时只列命中扩展名的文件（null = 任意文件）。
class _RealPathBrowser extends StatefulWidget {
  const _RealPathBrowser({
    required this.roots,
    required this.mode,
    required this.allowedExtensions,
  });

  /// 起始根目录集（安卓外置存储根，真实绝对路径）。
  final List<String> roots;

  /// 选目录本身还是下钻选文件。
  final _BrowserMode mode;

  /// 仅文件模式生效：null=任意文件；非空=按扩展名（不带点、小写）过滤子文件。
  final Set<String>? allowedExtensions;

  @override
  State<_RealPathBrowser> createState() => _RealPathBrowserState();
}

class _RealPathBrowserState extends State<_RealPathBrowser> {
  /// 当前浏览的目录；null = 停在根集列表（多根时让用户先选一个根）。
  String? _current;

  /// 当前 [_current] 是否就是某个根（用于决定「上一级」是回根集还是回父目录）。
  bool get _atRootList => _current == null;

  bool get _fileMode => widget.mode == _BrowserMode.file;

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
    // 根集列表只列目录（进根后才可能出现文件）。目录模式全程只列子目录；文件模式
    // 在具体目录里子目录 + 命中扩展名的文件都列（子目录在前，便于下钻）。
    final List<String> subdirs =
        _atRootList ? widget.roots : listSubdirectories(cur!);
    final List<String> files = (_atRootList || !_fileMode)
        ? const <String>[]
        : listFilesInDirectory(cur!,
            allowedExtensions: widget.allowedExtensions);
    // 拼成统一 entries：前 subdirs.length 项是目录（点击下钻），其后是文件
    // （点击 pop 回绝对路径）。用下标区分类型，避免额外包装类型。
    final List<String> entries = <String>[...subdirs, ...files];
    final int dirCount = subdirs.length;

    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (BuildContext context, ScrollController scrollController) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 表单顶部是工具栏 header（返回按钮 + 选择按钮），不是普通列表项，
              // 重建为 Padding+Row（不再用 ListTile）以走 MD3 共享组件守卫。
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: <Widget>[
                    _atRootList
                        ? const Icon(Icons.folder_open)
                        : IconButton(
                            icon: const Icon(Icons.arrow_back),
                            tooltip: t.folder_picker_up,
                            onPressed: _goUp,
                          ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            _atRootList
                                ? (_fileMode
                                    ? t.file_picker_title
                                    : t.folder_picker_title)
                                : p.basename(cur!).isEmpty
                                    ? cur
                                    : p.basename(cur),
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (!_atRootList)
                            Text(
                              cur!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    // 「选择此文件夹」按钮仅目录模式出现；文件模式靠点文件行确认。
                    if (!_atRootList && !_fileMode) ...<Widget>[
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, cur),
                        child: Text(t.folder_picker_select),
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Text(_fileMode
                            ? t.file_picker_empty
                            : t.folder_picker_empty),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: entries.length,
                        itemBuilder: (BuildContext context, int index) {
                          final String path = entries[index];
                          final bool isDir = index < dirCount;
                          final String label = p.basename(path).isEmpty
                              ? path
                              : p.basename(path);
                          return HibikiListTile(
                            icon: isDir
                                ? Icons.folder
                                : Icons.insert_drive_file_outlined,
                            selected: false,
                            title: label,
                            subtitle: '',
                            // 目录 → 下钻；文件 → pop 回其真实绝对路径。
                            onTap: () => isDir
                                ? _enter(path)
                                : Navigator.pop(context, path),
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
