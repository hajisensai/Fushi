import 'dart:io';

import 'package:fushi_server/src/config/server_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `torrent.peer_roots`：已配对设备借本机引擎下载时，除下载根外允许落盘的目录。
/// 只收绝对路径（相对路径在服务端没有确定含义），yaml 往返不丢。
void main() {
  final String abs = p.join(Directory.systemTemp.path, 'pc-library');

  test('yaml 往返保留 peer_roots', () {
    final ServerConfig config = ServerConfig.parse(
      // 单引号 yaml 标量不做转义：Windows 路径的反斜杠原样保留。
      "torrent:\n  peer_roots:\n    - '$abs'\n",
      configDir: '.',
    );
    expect(config.torrentPeerRoots, <String>[abs]);
    expect(
      ServerConfig.parse(config.toYaml(), configDir: '.').torrentPeerRoots,
      <String>[abs],
    );
  });

  test('缺省为空；相对路径直接拒绝', () {
    expect(ServerConfig.parse('', configDir: '.').torrentPeerRoots, isEmpty);
    expect(
      () => ServerConfig.parse(
        'torrent:\n  peer_roots:\n    - "relative/dir"\n',
        configDir: '.',
      ),
      throwsFormatException,
    );
    expect(
      () => ServerConfig.parseTorrentPeerRoots(<String>['x/y']),
      throwsFormatException,
    );
  });
}
