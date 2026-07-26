// 浏览器扩展镜像同步（G15）：`tools/browser-extension/` 是唯一真相源，
// `hibiki/assets/browser_extension/` 是随 app 打包的只读镜像（安装助手
// browser_extension_installer.dart 从 AssetManifest 解压它）。
//
// 历史上两镜像纯手工双写，已漂移过一次（58a7d4fa 修的就是 dict-media.js 漂移）。
// 本脚本让「同步」变成一条命令，配套守卫测试
// `test/build/browser_extension_mirror_full_guard_test.dart` 在 CI 单测门里做
// 全目录字节比对硬失败——改了 tools/ 忘跑本脚本会直接红。
//
// 用法（在 hibiki/ 下）：
//   dart run tool/sync_browser_extension.dart          # 同步 tools/ → assets/
//   dart run tool/sync_browser_extension.dart --check  # 只校验，漂移则退出码 1
//
// 镜像清单规则（与守卫测试保持一致，改这里必须同步改测试）：
//   tools/browser-extension/ 下全部文件，排除 `*.test.js`（Node 测试）与
//   `scripts/` 目录（构建工具，如 generate-content-css.mjs）；vendor/ 整目录纳入。
//   assets 侧不允许存在清单之外的多余文件（防止删除源文件后镜像残留）。
import 'dart:io';

import 'package:path/path.dart' as p;

/// 相对路径是否属于镜像清单（[rel] 用 `/` 分隔、相对 tools/browser-extension/）。
bool isMirroredExtensionFile(String rel) {
  if (rel.endsWith('.test.js')) return false;
  if (rel == 'scripts' || rel.startsWith('scripts/')) return false;
  return true;
}

/// 收集 [root] 下属于镜像清单的全部文件相对路径（`/` 分隔、字母序）。
List<String> collectMirroredFiles(Directory root) {
  final List<String> out = <String>[];
  for (final FileSystemEntity e in root.listSync(recursive: true)) {
    if (e is! File) continue;
    final String rel =
        p.relative(e.path, from: root.path).replaceAll('\\', '/');
    if (!isMirroredExtensionFile(rel)) continue;
    out.add(rel);
  }
  out.sort();
  return out;
}

void main(List<String> args) {
  final bool checkOnly = args.contains('--check');

  // 脚本位于 hibiki/tool/，据此定位仓库根，cwd 无关。
  final String scriptDir = p.dirname(Platform.script.toFilePath());
  final String hibikiRoot = p.normalize(p.join(scriptDir, '..'));
  final Directory source = Directory(
      p.normalize(p.join(hibikiRoot, '..', 'tools', 'browser-extension')));
  final Directory mirror =
      Directory(p.join(hibikiRoot, 'assets', 'browser_extension'));

  if (!source.existsSync()) {
    stderr.writeln('找不到源目录：${source.path}');
    exit(2);
  }

  final List<String> manifest = collectMirroredFiles(source);
  final List<String> existing =
      mirror.existsSync() ? collectMirroredFiles(mirror) : <String>[];

  final List<String> updated = <String>[];
  for (final String rel in manifest) {
    final File src = File(p.join(source.path, rel));
    final File dst = File(p.join(mirror.path, rel));
    final List<int> want = src.readAsBytesSync();
    if (dst.existsSync()) {
      final List<int> have = dst.readAsBytesSync();
      if (have.length == want.length) {
        bool same = true;
        for (int i = 0; i < want.length; i++) {
          if (have[i] != want[i]) {
            same = false;
            break;
          }
        }
        if (same) continue;
      }
    }
    updated.add(rel);
    if (!checkOnly) {
      dst.parent.createSync(recursive: true);
      dst.writeAsBytesSync(want);
    }
  }

  final Set<String> manifestSet = manifest.toSet();
  final List<String> stale =
      existing.where((String rel) => !manifestSet.contains(rel)).toList();
  if (!checkOnly) {
    for (final String rel in stale) {
      File(p.join(mirror.path, rel)).deleteSync();
    }
  }

  if (updated.isEmpty && stale.isEmpty) {
    stdout.writeln('镜像已同步（${manifest.length} 个文件，无漂移）。');
    return;
  }
  final String verb = checkOnly ? '漂移' : '已更新';
  for (final String rel in updated) {
    stdout.writeln('$verb: $rel');
  }
  for (final String rel in stale) {
    stdout.writeln(checkOnly ? '多余（源侧已删）: $rel' : '已删除残留: $rel');
  }
  if (checkOnly) {
    stderr.writeln('镜像漂移：跑 `dart run tool/sync_browser_extension.dart` 同步。');
    exit(1);
  }
  stdout.writeln('同步完成：更新 ${updated.length}、删除 ${stale.length}。');
}
