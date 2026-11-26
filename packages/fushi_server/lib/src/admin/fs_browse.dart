/// WebUI 路径框的「浏览…」选择器背后的目录清单（Sonarr / Radarr 选根目录那种）。
///
/// `GET /api/admin/fs/browse?path=<绝对路径>&files=1`：列出该目录的子目录（`files=1` 时连文件
/// 一起），附上级路径。只读、只列名字，不读文件内容；鉴权与其它 `/api/admin/*` 相同。
///
/// - `path` 为空或不是绝对路径：Windows 列盘符（「此电脑」，`path` 回空串），其它平台列 `/`。
/// - `path` 指向文件：打开它所在目录，并用 `selected` 标出这个文件（文件框回显当前值）。
/// - `path` 不存在：往上找最近的已存在目录打开，`fellBack: true`（手打了一半的路径也能接着点）。
/// - 目录读不了（权限）：抛 [FsBrowseException]（403），由路由转成错误回包。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

class FsBrowseException implements Exception {
  const FsBrowseException(this.status, this.message);
  final int status;
  final String message;

  @override
  String toString() => 'FsBrowseException($status: $message)';
}

class FsBrowser {
  FsBrowser({
    bool? isWindows,
    List<String> Function()? windowsDrives,
    this.maxEntries = 5000,
  }) : isWindows = isWindows ?? Platform.isWindows,
       _windowsDrives = windowsDrives ?? _existingWindowsDrives;

  final bool isWindows;
  final List<String> Function() _windowsDrives;

  /// 单个目录最多回这么多项（超出 `truncated: true`），防一个巨型目录把页面卡死。
  final int maxEntries;

  p.Context get _ctx =>
      p.Context(style: isWindows ? p.Style.windows : p.Style.posix);

  Future<Map<String, Object?>> browse(
    String? rawPath, {
    required bool includeFiles,
  }) async {
    final String raw = (rawPath ?? '').trim();
    if (raw.isEmpty || !_ctx.isAbsolute(raw)) {
      return _roots(includeFiles: includeFiles);
    }
    String dir = _normalize(raw);
    String? selected;
    bool fellBack = false;
    if (await FileSystemEntity.isFile(dir)) {
      selected = _ctx.basename(dir);
      dir = _ctx.dirname(dir);
    }
    while (!await Directory(dir).exists()) {
      final String up = _ctx.dirname(dir);
      if (up == dir) return _roots(includeFiles: includeFiles);
      dir = up;
      fellBack = true;
      selected = null;
    }
    return <String, Object?>{
      'path': dir,
      'parent': _parentOf(dir),
      'separator': _ctx.separator,
      ..._listing(dir, includeFiles: includeFiles),
      if (selected != null) 'selected': selected,
      if (fellBack) 'fellBack': true,
    };
  }

  /// `C:` → `C:\`，去掉多余分隔符与 `..`；根目录保留末尾分隔符。
  String _normalize(String raw) {
    String v = _ctx.normalize(raw);
    if (isWindows && RegExp(r'^[A-Za-z]:$').hasMatch(v)) v = '$v\\';
    return v;
  }

  /// 根目录的上级：Windows 回到盘符清单（空串），其它平台没有上级。
  String? _parentOf(String dir) {
    final String up = _ctx.dirname(dir);
    if (up != dir) return up;
    return isWindows ? '' : null;
  }

  Map<String, Object?> _roots({required bool includeFiles}) {
    if (!isWindows) {
      // 非 Windows 只有一个根：直接打开 `/`。
      final Map<String, Object?> root = _listing(
        '/',
        includeFiles: includeFiles,
      );
      return <String, Object?>{
        'path': '/',
        'parent': null,
        'separator': '/',
        ...root,
      };
    }
    return <String, Object?>{
      'path': '',
      'parent': null,
      'separator': r'\',
      'entries': <Map<String, Object?>>[
        for (final String d in _windowsDrives())
          <String, Object?>{'name': d, 'path': d, 'dir': true},
      ],
      'truncated': false,
    };
  }

  Map<String, Object?> _listing(String dir, {required bool includeFiles}) {
    final List<_Entry> entries = <_Entry>[];
    try {
      for (final FileSystemEntity e in Directory(
        dir,
      ).listSync(followLinks: false)) {
        // 链接按目标类型算；断链两边都不是，跳过。
        final FileSystemEntityType t = e is Link
            ? FileSystemEntity.typeSync(e.path)
            : (e is Directory
                  ? FileSystemEntityType.directory
                  : FileSystemEntityType.file);
        final bool isDir = t == FileSystemEntityType.directory;
        if (!isDir && (!includeFiles || t != FileSystemEntityType.file)) {
          continue;
        }
        entries.add(_Entry(_ctx.basename(e.path), e.path, isDir));
      }
    } on FileSystemException catch (e) {
      throw FsBrowseException(
        403,
        'cannot read $dir: ${e.osError?.message ?? e.message}',
      );
    }
    entries.sort((_Entry a, _Entry b) {
      if (a.dir != b.dir) return a.dir ? -1 : 1;
      final int c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    final bool truncated = entries.length > maxEntries;
    return <String, Object?>{
      'entries': <Map<String, Object?>>[
        for (final _Entry e
            in truncated ? entries.sublist(0, maxEntries) : entries)
          <String, Object?>{'name': e.name, 'path': e.path, 'dir': e.dir},
      ],
      'truncated': truncated,
    };
  }

  static List<String> _existingWindowsDrives() => <String>[
    for (int c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++)
      if (Directory('${String.fromCharCode(c)}:\\').existsSync())
        '${String.fromCharCode(c)}:\\',
  ];
}

class _Entry {
  const _Entry(this.name, this.path, this.dir);
  final String name;
  final String path;
  final bool dir;
}
