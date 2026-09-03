import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/ankiconnect_addon_installer.dart';
import 'package:fushi/src/anki/ankiconnect_port_repair.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ankiconnect_port_repair_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('端口空闲探测', () {
    test('被占用的端口报不空闲，释放后报空闲', () async {
      final ServerSocket squatter = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int port = squatter.port;
      // 判据必须是「能不能 bind」——这正是 AnkiConnect 启动时做的事。占用者只监听、
      // 不应答，也照样把端口占死，用 HTTP 探活是探不出来的。
      expect(await ankiConnectPortIsFree(port), isFalse);
      await squatter.close();
      expect(await ankiConnectPortIsFree(port), isTrue);
    });

    test('越界端口一律报不空闲，不去 bind', () async {
      expect(await ankiConnectPortIsFree(0), isFalse);
      expect(await ankiConnectPortIsFree(80), isFalse);
      expect(await ankiConnectPortIsFree(70000), isFalse);
    });
  });

  group('挑空闲端口', () {
    test('跳过当前端口——把不好使的那个选回来等于什么都没做', () async {
      final int? port = await findFreeAnkiConnectPort(
        exclude: kAnkiConnectPortScanStart,
        start: kAnkiConnectPortScanStart,
        count: 50,
      );
      expect(port, isNotNull);
      expect(port, isNot(kAnkiConnectPortScanStart));
    });

    test('候选段被占满时返回 null，而不是硬塞一个占用的端口', () async {
      final ServerSocket a = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final ServerSocket b = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() async {
        await a.close();
        await b.close();
      });
      // 把扫描窗口正好框在两个已占端口上（连号不保证，所以逐个当 start 试一次
      // count=1 的扫描：两次都必须落空）。
      expect(await findFreeAnkiConnectPort(start: a.port, count: 1), isNull);
      expect(await findFreeAnkiConnectPort(start: b.port, count: 1), isNull);
    });
  });

  group('写 AnkiConnect 插件配置', () {
    Directory addonDir() =>
        Directory(p.join(tmp.path, 'addons21', kAnkiConnectAddonId));

    test('写 config.webBindPort，保留 meta.json 里其余字段', () async {
      addonDir().createSync(recursive: true);
      File(p.join(addonDir().path, 'meta.json')).writeAsStringSync(
        json.encode(<String, dynamic>{
          'disabled': false,
          'mod': 12345,
          'config': <String, dynamic>{
            'webBindPort': 8765,
            'apiKey': 'secret',
            'webCorsOriginList': <String>['http://localhost'],
          },
        }),
      );

      final AnkiConnectPortWriteResult result = await writeAnkiConnectAddonPort(
        8790,
        ankiDataDir: tmp,
      );

      expect(result.status, AnkiConnectPortWriteStatus.updated);
      final Map<String, dynamic> meta =
          json.decode(
                File(p.join(addonDir().path, 'meta.json')).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final Map<String, dynamic> config =
          meta['config'] as Map<String, dynamic>;
      expect(config['webBindPort'], 8790);
      // 用户改过的其它插件配置不能被这次写端口顺手抹掉。
      expect(config['apiKey'], 'secret');
      expect(config['webCorsOriginList'], <String>['http://localhost']);
      expect(meta['mod'], 12345);
      expect(meta['disabled'], isFalse);
    });

    test('meta.json 不存在时写出只含端口的骨架', () async {
      addonDir().createSync(recursive: true);

      final AnkiConnectPortWriteResult result = await writeAnkiConnectAddonPort(
        8791,
        ankiDataDir: tmp,
      );

      expect(result.status, AnkiConnectPortWriteStatus.updated);
      final Map<String, dynamic> meta =
          json.decode(
                File(p.join(addonDir().path, 'meta.json')).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect((meta['config'] as Map<String, dynamic>)['webBindPort'], 8791);
    });

    test('meta.json 坏了当缺失处理，不抛', () async {
      addonDir().createSync(recursive: true);
      File(
        p.join(addonDir().path, 'meta.json'),
      ).writeAsStringSync('{ not json');

      final AnkiConnectPortWriteResult result = await writeAnkiConnectAddonPort(
        8792,
        ankiDataDir: tmp,
      );

      expect(result.status, AnkiConnectPortWriteStatus.updated);
      final Map<String, dynamic> meta =
          json.decode(
                File(p.join(addonDir().path, 'meta.json')).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect((meta['config'] as Map<String, dynamic>)['webBindPort'], 8792);
    });

    test('插件目录不存在时报 addonNotFound，不凭空造一个插件目录', () async {
      final AnkiConnectPortWriteResult result = await writeAnkiConnectAddonPort(
        8793,
        ankiDataDir: tmp,
      );

      expect(result.status, AnkiConnectPortWriteStatus.addonNotFound);
      expect(addonDir().existsSync(), isFalse);
    });

    test('Anki 数据目录不存在时报 addonNotFound', () async {
      final AnkiConnectPortWriteResult result = await writeAnkiConnectAddonPort(
        8794,
        ankiDataDir: Directory(p.join(tmp.path, 'does-not-exist')),
      );

      expect(result.status, AnkiConnectPortWriteStatus.addonNotFound);
    });
  });
}
