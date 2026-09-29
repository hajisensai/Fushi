import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show interconnectStickerLinkFor;
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';

/// 扫码 / 深链 / NFC 配对的入口面（docs/specs/2026-09-28-interconnect-remote-reach.md §4）。
void main() {
  test('NFC 贴纸链接：不带票据，地址种类由 URL 推断，指纹取自同组 https 条目', () {
    const List<FushiClientUrl> urls = <FushiClientUrl>[
      FushiClientUrl(
        url: 'https://home.example',
        hostId: 'A',
        deviceName: 'PC',
        fingerprintSha256: 'aa:bb',
        token: 'secret-token',
      ),
      FushiClientUrl(
        url: 'http://192.168.1.5:38765',
        hostId: 'A',
        learned: true,
      ),
      FushiClientUrl(url: 'http://[2408::5]:38765', hostId: 'A', learned: true),
      FushiClientUrl(url: 'http://other:1', hostId: 'B'),
    ];
    final FushiPairLink link = interconnectStickerLinkFor(urls, urls.first)!;
    expect(link.hasTicket, isFalse);
    expect(link.hostId, 'A');
    expect(link.fingerprint, 'aa:bb');
    final String uri = link.toUri();
    expect(uri.contains('secret-token'), isFalse, reason: '贴纸绝不能带凭据');
    expect(uri.contains('other'), isFalse, reason: '只含这一台 host');
    expect(
      <String, InterconnectAddressKind>{
        for (final InterconnectHostAddress a in link.addresses) a.url: a.kind,
      },
      <String, InterconnectAddressKind>{
        'https://home.example': InterconnectAddressKind.public,
        'http://192.168.1.5:38765': InterconnectAddressKind.lan,
        'http://[2408::5]:38765': InterconnectAddressKind.ipv6,
      },
    );
    expect(
      interconnectStickerLinkFor(urls, const FushiClientUrl(url: 'x')),
      isNull,
      reason: '没有 hostId 的老条目组不出贴纸',
    );
  });

  test('main.dart 的三个深链入口都认 fushi://pair，且统一走确认后配对', () {
    final String main = File('lib/main.dart').readAsStringSync();
    // 冷启动 argv（Windows 协议注册）、移动端 intent / iOS URL、Windows 单实例转发。
    expect(
      RegExp(r'FushiPairLink\.tryParse\(').allMatches(main).length,
      greaterThanOrEqualTo(4),
      reason: '三个入口 + 队列消费各一次',
    );
    expect(main.contains('_pendingPairLinks.add(arg)'), isTrue);
    expect(main.contains('_queuePairLink(data)'), isTrue);
    expect(main.contains('_queuePairLink(videoPath)'), isTrue);
    expect(
      main.contains('runInterconnectLinkPairingFlow('),
      isTrue,
      reason: '深链只能走带确认框的那条流程，不能直接调编排',
    );
    expect(main.contains('pairWithInterconnectLink('), isFalse);
  });

  test('Android manifest 声明了 fushi://pair 的 VIEW 与 NFC 入口', () {
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(
      RegExp(
        r'android:scheme="fushi"\s+android:host="pair"',
      ).allMatches(manifest).length,
      2,
    );
    expect(manifest.contains('android.nfc.action.NDEF_DISCOVERED'), isTrue);
    expect(
      manifest.contains('android.hardware.nfc" android:required="false"'),
      isTrue,
      reason: '没有 NFC 的设备也要能装',
    );
  });
}
