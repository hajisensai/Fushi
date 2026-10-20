// BUG-3571 守卫：生产代码只能经工作 isolate 的客户端使用内置 libtorrent。
//
// libtorrent 的 session 查询（`get_torrents` / `status` / 逐种子 `find_torrent`）
// 都是同步等网络线程回话的 FFI，启动加载 fastResume 时一次就能卡几秒。宿主
// 曾整套跑在 UI isolate 上，看门狗为此写过多份 hang dump。修复把宿主连同
// session 搬进 `EmbeddedTorrentWorker` 的专用 isolate，app（UI isolate）与
// 无头服务端（HTTP 事件循环）只持 `EmbeddedTorrentHostClient` /
// `EmbeddedTorrentBackendProxy`。
//
// 这条边界失效是静默的：直接 `EmbeddedTorrentHost.open` 照样能编译、能下载，
// 只是又会在用户机上偶发冻屏。所以在源码层钉死：`fushi/lib` 与
// `packages/fushi_server/lib` 里不得出现宿主 / session / 引擎 / 同步后端这几个
// 类型；唯一例外是只加载 DLL、不建 session 的静态探测。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// 宿主上允许在 UI isolate 调的静态成员：都只加载 DLL / 读缓存，不建 session。
const Set<String> _allowedHostStatics = <String>{
  'probeAvailable',
  'probeCapabilities',
  'lastProbeFailure',
};

final RegExp _forbiddenTypes = RegExp(
  r'\b(EmbeddedTorrentSession|EmbeddedTorrentEngine|EmbeddedTorrentBackend|'
  r'EmbeddedPauseControl)\b',
);

final RegExp _hostUse = RegExp(r'\bEmbeddedTorrentHost\b(?:\.(\w+))?');

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((File f) => f.path.endsWith('.dart'));

void main() {
  final List<String> roots = <String>['lib', '../packages/fushi_server/lib'];

  test('扫描面非空（防路径漂移导致的假绿）', () {
    for (final String root in roots) {
      expect(_dartFiles(root), isNotEmpty, reason: root);
    }
    final String appModel = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
    expect(appModel.contains('EmbeddedTorrentHostClient'), isTrue);
  });

  test('生产代码不直接持有内置引擎的宿主 / session / 同步后端', () {
    final List<String> offenders = <String>[];
    for (final String root in roots) {
      for (final File file in _dartFiles(root)) {
        final String code = maskCommentsAndStrings(file.readAsStringSync());
        for (final Match m in _forbiddenTypes.allMatches(code)) {
          offenders.add('${file.path}: ${m.group(0)}');
        }
        for (final Match m in _hostUse.allMatches(code)) {
          final String? member = m.group(1);
          if (member != null && _allowedHostStatics.contains(member)) continue;
          offenders.add('${file.path}: ${m.group(0)}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'BUG-3571：经 EmbeddedTorrentHostClient / '
          'EmbeddedTorrentBackendProxy 使用内置引擎，libtorrent 的同步 FFI '
          '只能在工作 isolate 里跑',
    );
  });
}
