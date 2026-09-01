import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/torrent/download_timeouts.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/net/app_http.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';

import '../helpers/source_guard.dart';

/// 统一代理（2026-08-29）：全应用只有系统设置里的一个代理项，默认自动
/// （手填 > env > 系统代理 > 直连）。下载发现链路（AniList / Nyaa / Torznab /
/// Jimaku / OpenSubtitles）曾有自己的三态（auto / direct / custom，默认 direct，
/// BUG-1538），同一台机器上「更新能走代理、搜番剧不能」；现已删除，这条链路与
/// 其它公网出站共用同一个出口。P2P（torrent）传输单独列出：默认直连（走代理
/// 可能降速，且不少代理服务商禁 BT），用户明确开了才经 ht_apply_proxy 下发给
/// libtorrent。
///
/// 本文件钉四件事：
///   A. 下载 client 仍保留本链路特有的 10s 建连超时（走统一装配点的参数）。
///   B. 下载出口跟随全局手填代理，且是**请求时现读**——改了代理不需要重建管线
///      里持有的长活 client；非法值 fail-open，绝不产出 `PROXY garbage`。
///   C. 第二套代理配置不得复活：生产源码里不再有 `DownloadNetworkProxy*` /
///      `download_network_proxy_mode` / `download_custom_proxy`（唯一例外是
///      fushi_core 的 v90 迁移，它删这两个键）。
///   D. P2P（torrent）传输**默认直连**，三档 direct / proxy / mixed（混合：
///      tracker 经代理、DHT 与 peer 直连）；开关语义钉在 resolveP2pProxyHostPort
///      一处，torrent 宿主/绑定不碰代理解析层，C ABI 桥只有 apply_proxy_impl
///      一处能改 libtorrent 代理（两个导出都只是委托）。
///   E. 混合档的 DHT 直连依赖 vcpkg overlay 里的 libtorrent 补丁（上游把无
///      flag UDP 无条件塞进代理）；监听接口默认 v4+v6 双栈；节点获取默认
///      开满（逐 tracker announce + DHT 多引导点）。
void main() {
  group('A. 建连超时', () {
    test('下载 client 的建连超时是 kDownloadConnectionTimeout 而不是 app 默认', () {
      final HttpClient client =
          createAppHttpClient(connectionTimeout: kDownloadConnectionTimeout);
      addTearDown(() => client.close(force: true));
      expect(client.connectionTimeout, kDownloadConnectionTimeout);
      expect(kDownloadConnectionTimeout, isNot(kAppHttpConnectionTimeout),
          reason: '两者相等的话这条参数就没有存在的意义，守卫也失去判别力');
    });
  });

  group('B. 出口跟随全局代理，请求时现读', () {
    late String Function() savedReader;
    setUp(() => savedReader = appUserProxyReader);
    tearDown(() => appUserProxyReader = savedReader);

    test('手填代理改变后，同一个 findProxy 立刻给出新出口', () {
      final HttpClient client =
          createAppHttpClient(connectionTimeout: kDownloadConnectionTimeout);
      addTearDown(() => client.close(force: true));
      // createAppHttpClient 装的就是 resolveAppProxyDirective；直接对它断言，
      // 不必发真实请求。
      final Uri nyaa = Uri.parse('https://nyaa.si/?q=test');

      appUserProxyReader = () => '127.0.0.1:7890';
      expect(resolveAppProxyDirective(nyaa), 'PROXY 127.0.0.1:7890');

      appUserProxyReader = () => '10.1.1.1:8080';
      expect(resolveAppProxyDirective(nyaa), 'PROXY 10.1.1.1:8080',
          reason: '闭包必须每次重读真相源，否则改代理要重启/重建管线才生效');
    });

    test('非法手填值 fail-open：不会产出 PROXY garbage', () {
      appUserProxyReader = () => 'not a proxy';
      final String directive =
          resolveAppProxyDirective(Uri.parse('https://nyaa.si/'));
      expect(directive, isNot(contains('not a proxy')));
      expect(directive, anyOf('DIRECT', startsWith('PROXY ')));
    });

    test('本机 / 局域网目标（qBittorrent WebUI、Torznab 自建）永远直连', () {
      appUserProxyReader = () => '127.0.0.1:7890';
      expect(
        resolveAppProxyDirective(Uri.parse('http://127.0.0.1:8080/api')),
        'DIRECT',
      );
      expect(
        resolveAppProxyDirective(Uri.parse('http://192.168.1.10:9117/')),
        'DIRECT',
      );
    });
  });

  group('C. 第二套代理配置不得复活', () {
    test('生产源码里没有下载域独立代理符号（迁移除外）', () {
      const List<String> roots = <String>[
        'lib',
        '../packages/fushi_core/lib',
        '../packages/fushi_torrent/lib',
        '../packages/fushi_audio/lib',
        '../packages/fushi_platform/lib',
      ];
      const Set<String> exempt = <String>{
        // v90 迁移：归并 + 删除这两个键，字面量必然出现在 SQL 里。
        'packages/fushi_core/lib/src/database/database.dart',
      };
      const List<String> forbidden = <String>[
        'DownloadNetworkProxy',
        'download_network_proxy_mode',
        'download_custom_proxy',
        'downloadNetworkProxyMode',
        'downloadCustomProxy',
      ];
      final List<String> offenders = <String>[];
      int scanned = 0;
      for (final String root in roots) {
        final Directory dir = Directory(root);
        expect(dir.existsSync(), isTrue, reason: '守卫必须从 fushi/ 运行：$root');
        for (final FileSystemEntity e in dir.listSync(recursive: true)) {
          if (e is! File || !e.path.endsWith('.dart')) continue;
          final String normalized = e.path.replaceAll(r'\', '/');
          if (exempt.any(normalized.endsWith)) continue;
          scanned++;
          final String code = maskComments(e.readAsStringSync());
          for (final String needle in forbidden) {
            if (code.contains(needle)) {
              offenders.add('$normalized: $needle');
            }
          }
        }
      }
      expect(scanned, greaterThan(500), reason: '扫描面异常缩小，守卫可能空转');
      expect(offenders, isEmpty,
          reason: '下载域不得再有独立代理配置，代理只在系统设置一处 → $offenders');
    });
  });

  group('D. P2P 传输：默认直连，单独开关才跟全局代理', () {
    late String Function() savedReader;
    setUp(() => savedReader = appUserProxyReader);
    tearDown(() => appUserProxyReader = savedReader);

    test('fresh PreferencesRepository：P2P 代理档位默认 direct', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final PreferencesRepository repo = PreferencesRepository(db);
      await repo.loadFromDb();
      expect(repo.p2pProxyMode, 'direct',
          reason: '走代理可能降速且不少代理服务商禁 BT，必须由用户明确改档');
      await repo.setP2pProxyMode('mixed');
      expect(repo.p2pProxyMode, 'mixed');
      await repo.setP2pProxyMode('proxy');
      expect(repo.p2pProxyMode, 'proxy');
    });

    test('旧布尔键迁移：mode 键未写过时 true → proxy；set 写穿旧键保降级一致',
        () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final PreferencesRepository repo = PreferencesRepository(db);
      await repo.loadFromDb();
      // 模拟老版本只写过布尔开关的库。
      await repo.setPref('network_proxy_p2p_enabled', true);
      expect(repo.p2pProxyMode, 'proxy',
          reason: '旧版本开过代理的用户升级后不能被静默改回直连');
      // 三态写入后写穿旧键：降级回老版本读到一致语义（mixed 按「开」处理）。
      await repo.setP2pProxyMode('mixed');
      expect(
          repo.getPref('network_proxy_p2p_enabled', defaultValue: false), true);
      await repo.setP2pProxyMode('direct');
      expect(repo.getPref('network_proxy_p2p_enabled', defaultValue: true),
          false);
    });

    test('开关关 → 下发 null（直连），哪怕全局手填了代理；开 → 与全局同一出口', () {
      appUserProxyReader = () => '127.0.0.1:7890';
      expect(resolveP2pProxyHostPort(enabled: false), isNull);
      expect(resolveP2pProxyHostPort(enabled: true), '127.0.0.1:7890');
      // 与 HttpClient 侧的裁决同源：同一时刻两边给出同一个出口。
      expect(
        resolveAppProxyDirective(Uri.parse('https://nyaa.si/')),
        'PROXY ${resolveP2pProxyHostPort(enabled: true)}',
      );
    });

    test('proxyHostPortFromDirective：取第一个 PROXY，DIRECT/空 → null', () {
      expect(proxyHostPortFromDirective('DIRECT'), isNull);
      expect(proxyHostPortFromDirective(''), isNull);
      expect(
          proxyHostPortFromDirective('PROXY 10.0.0.1:8080'), '10.0.0.1:8080');
      expect(
        proxyHostPortFromDirective('PROXY a.lan:1; PROXY b.lan:2; DIRECT'),
        'a.lan:1',
      );
      expect(proxyHostPortFromDirective('proxy X:3'), 'X:3',
          reason: '关键字大小写不敏感');
      expect(proxyHostPortFromDirective('PROXY '), isNull);
    });

    test('torrent 引擎 Dart 绑定 / 嵌入宿主不 import app 代理层，也不自己解析代理', () {
      // 宿主只接受「一个 host:port 或 null」；「该不该走、走哪个」是 AppModel 经
      // resolveP2pProxyHostPort 裁决的，这样默认直连的语义只钉在一个函数上。
      const List<String> targets = <String>[
        '../packages/fushi_torrent/lib',
        'lib/src/media/torrent/embedded_torrent_host.dart',
        'lib/src/media/torrent/embedded_torrent_backend.dart',
      ];
      const List<String> forbidden = <String>[
        'app_proxy.dart',
        'app_http.dart',
        'applyAppProxy',
        'findProxy',
        'appUserProxyReader',
        'resolveAppProxy',
      ];
      final List<String> offenders = <String>[];
      int scanned = 0;
      for (final String target in targets) {
        final List<File> files;
        if (FileSystemEntity.isDirectorySync(target)) {
          files = Directory(target)
              .listSync(recursive: true)
              .whereType<File>()
              .where((File f) => f.path.endsWith('.dart'))
              .toList();
        } else {
          final File f = File(target);
          expect(f.existsSync(), isTrue, reason: '找不到 $target（被移动？）');
          files = <File>[f];
        }
        for (final File f in files) {
          scanned++;
          final String code = maskComments(f.readAsStringSync());
          for (final String needle in forbidden) {
            if (code.contains(needle)) {
              offenders.add('${f.path.replaceAll(r'\', '/')}: $needle');
            }
          }
        }
      }
      expect(scanned, greaterThanOrEqualTo(4));
      expect(offenders, isEmpty,
          reason: 'torrent 宿主/绑定不得自己碰代理解析层 → $offenders');
    });

    test('C ABI 桥：libtorrent 代理设置只住在 apply_proxy_impl 里，开 session 不带代理', () {
      final File bridge = File('../native/fushi_torrent/fushi_torrent_ffi.cpp');
      expect(bridge.existsSync(), isTrue);
      final String code = maskComments(bridge.readAsStringSync());
      final int start = code.indexOf('static int apply_proxy_impl(');
      expect(start, greaterThan(0), reason: '桥必须有 apply_proxy_impl 单点');
      final int end = code.indexOf('HT_EXPORT', start + 1);
      expect(end, greaterThan(start));
      final String body = code.substring(start, end);
      // 三条链路必须在同一处裁决（散落多处会让某条从真实出口漏出去）。
      for (final String key in <String>[
        'proxy_peer_connections',
        'proxy_tracker_connections',
        'proxy_hostnames',
      ]) {
        expect(body, contains('settings_pack::$key'),
            reason: 'apply_proxy_impl 必须同时设置 $key');
      }
      // 混合档语义钉死：peer 面（含 DHT，见 overlay 补丁）在 mixed 时豁免，
      // tracker / 主机名解析仍经代理。
      expect(body, contains('proxy_peer_connections, enabled && !mixed'));
      expect(body, contains('proxy_tracker_connections, enabled)'));
      // 两个导出都存在且只委托（导出体里不得再碰 settings_pack::proxy_*）。
      expect(code, contains('HT_EXPORT int ht_apply_proxy('),
          reason: '旧 ABI 必须保留（老 Dart 层/外部调用者）');
      expect(code, contains('HT_EXPORT int ht_apply_proxy_mode('),
          reason: '混合档依赖新导出');
      final String outside = code.substring(0, start) + code.substring(end);
      expect(outside, isNot(contains('settings_pack::proxy_')),
          reason: '开 session / 其它设置入口不得偷偷带上代理：'
              'P2P 默认直连，只有 apply_proxy_impl 一处能改');
    });

    test('设置页：P2P 三档列在网络分区，副标题就是降速/封号/暴露 IP 警告', () {
      final String code = compactCode(
        File('lib/src/settings/settings_schema_system.dart').readAsStringSync(),
      );
      expect(code, contains("id:'system.network_proxy_p2p'"));
      expect(code, contains('subtitle:t.network_proxy_p2p_warning'));
      expect(
          code,
          contains('selected:(SettingsContextsettingsContext)=>'
              'settingsContext.appModel.p2pProxyMode'));
      // 三档一个不能少；值与 prefs 层字面量一致。
      for (final String value in <String>['direct', 'proxy', 'mixed']) {
        expect(code, contains("value:'$value'"),
            reason: 'P2P 代理三档缺 $value');
      }
    });
  });

  group('E. 混合档 DHT 直连补丁与双栈监听', () {
    test('libtorrent overlay 补丁存在、被 portfile 引用、构建脚本挂 overlay', () {
      final File patch = File(
          '../native/fushi_torrent/vcpkg-ports/libtorrent/'
          'dht-follows-peer-proxy-exemption.patch');
      expect(patch.existsSync(), isTrue,
          reason: '混合档 DHT 直连依赖此补丁：上游 udp_socket.cpp 把无 flag '
              'UDP（DHT）在配了代理时无条件塞进代理，HTTP 代理下 DHT 判死');
      final String patchText = patch.readAsStringSync();
      // 发送路径两处 use_proxy 表达式都要打上（send_hostname + send）。
      expect(
          RegExp(r'\+\s+&& m_proxy_settings\.proxy_peer_connections\)')
              .allMatches(patchText)
              .length,
          2,
          reason: 'DHT 豁免必须同时对齐两条发送路径');
      final String portfile = File(
              '../native/fushi_torrent/vcpkg-ports/libtorrent/portfile.cmake')
          .readAsStringSync();
      expect(portfile, contains('dht-follows-peer-proxy-exemption.patch'),
          reason: '补丁文件在而 portfile 不引用 = 构建出的库没有豁免');
      for (final String script in <String>[
        '../native/fushi_torrent/build_windows_dll.ps1',
        '../native/fushi_torrent/build_android_so.ps1',
        // CI（release.yml）走的是 bash 版，本机走 .ps1——两套都得挂 overlay。
        '../native/fushi_torrent/build_android_so.sh',
      ]) {
        expect(File(script).readAsStringSync(),
            contains('VCPKG_OVERLAY_PORTS'),
            reason: '$script 不挂 overlay ports = 补丁静默失效');
      }
    });

    test('监听接口默认 v4+v6 双栈（与 ht_apply_session_settings 端口重设同形）', () {
      final String host = maskComments(
        File('lib/src/media/torrent/embedded_torrent_host.dart')
            .readAsStringSync(),
      );
      expect(host, contains("listenInterfaces = '0.0.0.0:6881,[::]:6881'"),
          reason: '此前建号 v4-only、用户改端口后才双栈——同一开关两种行为；'
              'IPv6 DHT/peer 是节点获取范围的重要组成');
    });

    test('节点获取默认开满：逐 tracker announce 双开 + DHT 多引导点，且设在建号处', () {
      final String code = maskComments(
        File('../native/fushi_torrent/fushi_torrent_ffi.cpp')
            .readAsStringSync(),
      );
      // 必须设在 ht_session_create（建号一次长效）；ht_apply_session_settings
      // 的 pack 不含这些键，出现在别处说明有人把语义挪散了。
      final int start = code.indexOf('HT_EXPORT void* ht_session_create(');
      expect(start, greaterThan(0));
      final int end = code.indexOf('HT_EXPORT', start + 1);
      final String body = code.substring(start, end);
      expect(body, contains('announce_to_all_trackers, true'),
          reason: 'libtorrent 默认只向同 tier 第一个应答的 tracker 要 peer，'
              '多 tracker 种子的其余 tracker 全闲置');
      expect(body, contains('announce_to_all_tiers, true'));
      expect(body, contains('dht_bootstrap_nodes'),
          reason: '默认引导点只有 dht.libtorrent.org 一个，冷启动单点');
      for (final String node in <String>[
        'dht.libtorrent.org:25401',
        'router.bittorrent.com:6881',
        'router.utorrent.com:6881',
        'dht.transmissionbt.com:6881',
      ]) {
        expect(body, contains(node), reason: 'DHT 引导点清单缺 $node');
      }
      final String outside = code.substring(0, start) + code.substring(end);
      expect(outside, isNot(contains('announce_to_all')),
          reason: '逐 tracker announce 只在建号处裁决一次');
      expect(outside, isNot(contains('dht_bootstrap_nodes')),
          reason: 'DHT 引导点只在建号处裁决一次');
    });
  });
}
