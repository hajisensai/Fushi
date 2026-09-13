import 'dart:io';

import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/native_libs.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('bundle 布局：bin/<exe> 旁与 ../lib 都是候选，lib 命中', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('fushi_libs_');
    addTearDown(() => tmp.delete(recursive: true));
    final String exe = p.join(tmp.path, 'bundle', 'bin', 'fushi_server');
    final File so = File(p.join(tmp.path, 'bundle', 'lib', 'libx.so'));
    await so.create(recursive: true);

    final List<String> candidates = bundledLibraryCandidates('libx.so', executablePath: exe);
    expect(candidates.first, p.join(tmp.path, 'bundle', 'bin', 'libx.so'));
    expect(candidates[1], p.normalize(so.path));
    expect(locateBundledLibrary('libx.so', executablePath: exe), p.normalize(so.path));
    expect(locateBundledLibrary('libnope.so', executablePath: exe), isNull);
  });

  test('torrent 段：默认 auto，非法 engine 报错，往返一致', () {
    final ServerConfig d = ServerConfig.parse('', configDir: '/x');
    expect(d.torrentEngine, ServerConfig.torrentEngineAuto);
    expect(d.torrentListen, ServerConfig.defaultTorrentListen);
    expect(d.torrentLibraryPath, isNull);

    final ServerConfig c = ServerConfig.parse(
      'torrent:\n  engine: embedded\n  library: /opt/fushi/lib/libfushi_torrent_ffi.so\n  listen: "0.0.0.0:7000"\n',
      configDir: '/x',
    );
    expect(c.torrentEngine, ServerConfig.torrentEngineEmbedded);
    expect(c.torrentLibraryPath, '/opt/fushi/lib/libfushi_torrent_ffi.so');
    expect(c.torrentListen, '0.0.0.0:7000');
    final ServerConfig back = ServerConfig.parse(c.toYaml(), configDir: '/x');
    expect(back.torrentEngine, c.torrentEngine);
    expect(back.torrentLibraryPath, c.torrentLibraryPath);
    expect(back.torrentListen, c.torrentListen);

    expect(
      () => ServerConfig.parse('torrent:\n  engine: transmission\n', configDir: '/x'),
      throwsA(isA<FormatException>()),
    );
  });
}
