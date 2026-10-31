// srs.db 的打开不许跑在 UI isolate（3.1.0 安卓启动白屏）：
//
// `ffsrs_store_open` 会把库升级到当前格式（native/fushi_fsrs/src/store/schema.rs `migrate`：v17 ID 编码、
// v18 瘦 JSON 都是单事务整表重建），库大时要几分钟。Android / iOS 上 UI isolate 就跑在平台主线程，
// 在那里同步 `SrsCore.open` = 整段升级期间主线程被占，一帧都出不来、系统启动画面撤不掉。
//
// 所以 app 代码（fushi/lib 与 packages/*/lib）只许 `SrsCore.openInBackground`；同步的 `SrsCore.open`
// 只留给测试与已经身在后台 isolate 的代码（后者要进白名单并写明理由）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// 允许同步 `SrsCore.open(` 的 lib 文件（相对仓库根，`/` 分隔）→ 理由。
const Map<String, String> _kAllowed = <String, String>{};

/// 仓库根（测试在 fushi/ 下跑）。
final Directory _repo = Directory.current.parent;

String _rel(File f) =>
    p.relative(f.path, from: _repo.path).replaceAll(r'\', '/');

void main() {
  test('app 代码不在调用方 isolate 同步打开 srs.db', () {
    final List<Directory> roots = <Directory>[
      Directory(p.join(_repo.path, 'fushi', 'lib')),
      for (final FileSystemEntity e in Directory(
        p.join(_repo.path, 'packages'),
      ).listSync())
        if (e is Directory && Directory(p.join(e.path, 'lib')).existsSync())
          Directory(p.join(e.path, 'lib')),
    ];
    final RegExp syncOpen = RegExp(r'\bSrsCore\s*\.\s*open\s*\(');
    final List<String> offenders = <String>[];
    bool sawBackgroundOpen = false;
    for (final Directory root in roots) {
      for (final File f
          in root
              .listSync(recursive: true)
              .whereType<File>()
              .where((File f) => f.path.endsWith('.dart'))) {
        final String src = maskComments(f.readAsStringSync());
        final String rel = _rel(f);
        if (rel == 'packages/fushi_engine/lib/srs/srs_storage.dart' &&
            src.contains('SrsCore.openInBackground(')) {
          sawBackgroundOpen = true;
        }
        if (syncOpen.hasMatch(src) && !_kAllowed.containsKey(rel)) {
          offenders.add(rel);
        }
      }
    }
    expect(
      sawBackgroundOpen,
      isTrue,
      reason: 'SrsStorage.open 应经 SrsCore.openInBackground 打开（守卫扫描范围失效？）',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '这些文件在调用方 isolate 同步打开 srs.db（可能整段跑格式升级、卡死 UI 主线程）；'
          '改用 SrsCore.openInBackground',
    );
  });
}
