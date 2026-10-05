// BUG-2950：fake-ip DNS（Clash TUN 等）下内置 libtorrent 的 DHT 引导点与 UDP
// tracker 主机名全被解析成 198.18.x.x 假地址。修法是 AppModel 用 DoH 拿到真实
// IP 后经宿主下发两样东西：
// - DHT 节点 → EmbeddedTorrentHost.addDhtNodes → native ht_add_dht_nodes；
// - 真实 IP tracker → EmbeddedTorrentHost.setExtraTrackers：立即追加到现有
//   种子，并让 backendView 派发的后端给新任务追加。
//
// 本测试用 Pointer.fromFunction 伪造 C ABI，不依赖随包 native DLL，锁住：
// - 老 DLL 缺 ht_add_dht_nodes 时降级返回 -1、不崩；
// - 新 DLL 时节点按换行拼接下发、去重去空白；
// - 附加 tracker 落到现有种子与新任务（宿主更新后已派发的后端也现读）。

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_backend.dart';
import 'package:fushi_engine/media/torrent/embedded_torrent_host.dart';
import 'package:fushi_torrent/fushi_torrent.dart';

final Pointer<Void> _fakeSession = Pointer<Void>.fromAddress(0x2938);
final List<String> _calls = <String>[];

bool _hasDhtSymbol = true;
String _torrentsJson = '[]';
String _addResultJson = '{"ok":true,"id":"newhash"}';

Pointer<Void> _fakeSessionCreate(Pointer<Char> listen, int enableDht) =>
    _fakeSession;

int _fakeApplySessionSettings(
  Pointer<Void> session,
  int listenPort,
  int enableDht,
  int enableLsd,
  int enableUpnp,
  int enableNatpmp,
  int encPolicy,
  int anonymousMode,
  int activeDownloads,
  int activeSeeds,
  int maxUploadSlots,
) =>
    1;

Pointer<Char> _fakeListTorrents(Pointer<Void> session) =>
    _torrentsJson.toNativeUtf8().cast<Char>();

Pointer<Char> _fakeAddMagnet(
  Pointer<Void> session,
  Pointer<Char> magnet,
  Pointer<Char> savePath,
  int sequential,
) {
  _calls.add('add');
  return _addResultJson.toNativeUtf8().cast<Char>();
}

int _fakeAddTrackers(
  Pointer<Void> session,
  Pointer<Char> infoHash,
  Pointer<Char> urls,
) {
  final String id = infoHash.cast<Utf8>().toDartString();
  final String joined = urls.cast<Utf8>().toDartString();
  _calls.add('trackers:$id:${joined.split('\n').join('|')}');
  return joined.split('\n').length;
}

int _fakeAddDhtNodes(Pointer<Void> session, Pointer<Char> nodes) {
  final String joined = nodes.cast<Utf8>().toDartString();
  _calls.add('dht:${joined.split('\n').join('|')}');
  return joined.split('\n').length;
}

void _fakeFreeString(Pointer<Char> string) {
  if (string != nullptr) malloc.free(string);
}

FushiTorrentBindings _fakeBindings() {
  Pointer<T> lookup<T extends NativeType>(String symbol) {
    switch (symbol) {
      case 'ht_session_create':
        return Pointer.fromFunction<Pointer<Void> Function(Pointer<Char>, Int)>(
          _fakeSessionCreate,
        ).cast<T>();
      case 'ht_apply_session_settings':
        return Pointer.fromFunction<
            Int Function(Pointer<Void>, Int, Int, Int, Int, Int, Int, Int, Int,
                Int, Int)>(
          _fakeApplySessionSettings,
          0,
        ).cast<T>();
      case 'ht_list_torrents':
        return Pointer.fromFunction<Pointer<Char> Function(Pointer<Void>)>(
          _fakeListTorrents,
        ).cast<T>();
      case 'ht_add_magnet':
        return Pointer.fromFunction<
            Pointer<Char> Function(
                Pointer<Void>, Pointer<Char>, Pointer<Char>, Int)>(
          _fakeAddMagnet,
        ).cast<T>();
      case 'ht_add_trackers':
        return Pointer.fromFunction<
            Int Function(Pointer<Void>, Pointer<Char>, Pointer<Char>)>(
          _fakeAddTrackers,
          -1,
        ).cast<T>();
      case 'ht_add_dht_nodes':
        if (!_hasDhtSymbol) break;
        return Pointer.fromFunction<Int Function(Pointer<Void>, Pointer<Char>)>(
          _fakeAddDhtNodes,
          -1,
        ).cast<T>();
      case 'ht_free_string':
        return Pointer.fromFunction<Void Function(Pointer<Char>)>(
          _fakeFreeString,
        ).cast<T>();
    }
    throw ArgumentError("Failed to lookup symbol '$symbol'");
  }

  return FushiTorrentBindings.fromLookup(lookup);
}

String _torrent(String id) {
  return jsonEncode(<String, Object>{
    'id': id,
    'name': id,
    'progress': 0.5,
    'state': 'downloading',
    'save_path': '${_tempDir.path}${Platform.pathSeparator}content',
    'content_path': '',
    'total': 100,
    'done': 50,
    'left': 50,
    'down_rate': 0,
    'up_rate': 0,
    'uploaded': 0,
    'downloaded': 50,
    'num_peers': 0,
    'has_metadata': true,
    'is_finished': false,
    'is_seeding': false,
    'sequential': false,
  });
}

late Directory _tempDir;

EmbeddedTorrentHost _host() {
  final EmbeddedTorrentEngine engine =
      EmbeddedTorrentEngine.fromBindings(_fakeBindings());
  final EmbeddedTorrentSession? session = EmbeddedTorrentSession.open(engine);
  expect(session, isNotNull);
  return EmbeddedTorrentHost.forTesting(
    engine: engine,
    session: session!,
    baseSavePath: '${_tempDir.path}${Platform.pathSeparator}content',
    resumeDir: '${_tempDir.path}${Platform.pathSeparator}resume',
  );
}

void main() {
  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('torrent_fakeip_bypass_');
    _calls.clear();
    _hasDhtSymbol = true;
    _torrentsJson = '[]';
    _addResultJson = '{"ok":true,"id":"newhash"}';
  });

  tearDown(() {
    try {
      _tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄释放滞后；临时目录交给系统清理。
    }
  });

  group('addDhtNodes', () {
    test('老 DLL 缺 ht_add_dht_nodes：降级返回 -1，不调 native、不抛', () {
      _hasDhtSymbol = false;
      final EmbeddedTorrentHost host = _host();
      expect(host.addDhtNodes(<String>['1.2.3.4:6881']), -1);
      expect(_calls.where((String c) => c.startsWith('dht:')), isEmpty);
    });

    test('新 DLL：去空白去重后按换行拼接下发，返回 native 计数', () {
      final EmbeddedTorrentHost host = _host();
      expect(
        host.addDhtNodes(<String>[
          ' 67.215.246.10:6881 ',
          '67.215.246.10:6881',
          '',
          '87.98.162.88:6881',
        ]),
        2,
      );
      expect(_calls, <String>['dht:67.215.246.10:6881|87.98.162.88:6881']);
    });

    test('空列表 / 全空白：返回 -1 且不调 native', () {
      final EmbeddedTorrentHost host = _host();
      expect(host.addDhtNodes(<String>[]), -1);
      expect(host.addDhtNodes(<String>['  ']), -1);
      expect(_calls, isEmpty);
    });
  });

  group('setExtraTrackers', () {
    test('立即追加到 session 里现有的每个种子（去重去空白）', () {
      _torrentsJson = '[${_torrent('aaa')},${_torrent('bbb')}]';
      final EmbeddedTorrentHost host = _host();
      host.setExtraTrackers(<String>[
        'udp://1.2.3.4:1337/announce',
        ' udp://1.2.3.4:1337/announce ',
        '',
        'udp://5.6.7.8:6969/announce',
      ]);
      expect(host.extraTrackers, <String>[
        'udp://1.2.3.4:1337/announce',
        'udp://5.6.7.8:6969/announce',
      ]);
      expect(_calls, <String>[
        'trackers:aaa:udp://1.2.3.4:1337/announce|udp://5.6.7.8:6969/announce',
        'trackers:bbb:udp://1.2.3.4:1337/announce|udp://5.6.7.8:6969/announce',
      ]);
    });

    test('空列表：只清记录，不碰 native', () {
      _torrentsJson = '[${_torrent('aaa')}]';
      final EmbeddedTorrentHost host = _host();
      host.setExtraTrackers(<String>['udp://1.2.3.4:1337/announce']);
      _calls.clear();
      host.setExtraTrackers(<String>[]);
      expect(host.extraTrackers, isEmpty);
      expect(_calls, isEmpty);
    });

    test('backendView 新加的任务带上附加 tracker；已派发的后端现读宿主最新值', () async {
      final EmbeddedTorrentHost host = _host();
      final EmbeddedTorrentBackend backend = host.backendView();
      // 后端先派发、宿主后更新：适配器必须现读，不能拿派发时的快照。
      host.setExtraTrackers(<String>['udp://1.2.3.4:1337/announce']);
      _calls.clear();

      expect(
        await backend.addTorrent('magnet:?xt=urn:btih:newhash',
            category: 'hibiki'),
        isTrue,
      );
      expect(_calls, <String>[
        'add',
        'trackers:newhash:udp://1.2.3.4:1337/announce',
      ]);
    });

    test('没有附加 tracker 时新任务不追加 tracker', () async {
      final EmbeddedTorrentHost host = _host();
      final EmbeddedTorrentBackend backend = host.backendView();
      expect(
        await backend.addTorrent('magnet:?xt=urn:btih:newhash',
            category: 'hibiki'),
        isTrue,
      );
      expect(_calls, <String>['add']);
    });
  });
}
