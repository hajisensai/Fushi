import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/download_timeouts.dart';
import 'package:fushi/src/utils/net/app_http.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';

import '../helpers/source_guard.dart';

/// 统一代理（2026-08-29）：全应用只有系统设置里的一个代理项，默认自动
/// （手填 > env > 系统代理 > 直连）。下载发现链路（AniList / Nyaa / Torznab /
/// Jimaku / OpenSubtitles）曾有自己的三态（auto / direct / custom，默认 direct，
/// BUG-1538），同一台机器上「更新能走代理、搜番剧不能」；现已删除，这条链路与
/// 其它公网出站共用同一个出口。P2P（torrent）传输不在此列——BT 不是 HTTP，
/// 引擎里没有任何代理代码路径，始终直连。
///
/// 本文件钉四件事：
///   A. 下载 client 仍保留本链路特有的 10s 建连超时（走统一装配点的参数）。
///   B. 下载出口跟随全局手填代理，且是**请求时现读**——改了代理不需要重建管线
///      里持有的长活 client；非法值 fail-open，绝不产出 `PROXY garbage`。
///   C. 第二套代理配置不得复活：生产源码里不再有 `DownloadNetworkProxy*` /
///      `download_network_proxy_mode` / `download_custom_proxy`（唯一例外是
///      fushi_core 的 v89 迁移，它删这两个键）。
///   D. torrent 引擎（Dart 绑定 + 嵌入宿主 + C ABI 桥）不接 app 代理层。
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
        // v89 迁移：归并 + 删除这两个键，字面量必然出现在 SQL 里。
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

  group('D. P2P 传输不接代理层', () {
    test('torrent 引擎 Dart 绑定 / 嵌入宿主不 import app 代理层，也不设 findProxy', () {
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
          reason: 'P2P 传输始终直连，torrent 引擎不得接 app 代理层 → $offenders');
    });

    test('C ABI 桥不向 libtorrent session 下发任何代理设置', () {
      final File bridge = File('../native/fushi_torrent/fushi_torrent_ffi.cpp');
      expect(bridge.existsSync(), isTrue);
      final String code = maskComments(bridge.readAsStringSync()).toLowerCase();
      expect(code, isNot(contains('proxy')),
          reason: 'libtorrent 的 proxy_type / proxy_hostname 等设置项一个都不该出现：'
              'P2P 传输始终直连');
    });
  });
}
