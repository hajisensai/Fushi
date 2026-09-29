import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_link_pairing.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:http/http.dart' as http;

import 'temp_dir_cleanup.dart';

/// 扫码 / 深链 / NFC 配对（docs/specs/2026-09-28-interconnect-remote-reach.md §4）。
void main() {
  group('FushiPairLink', () {
    const FushiPairLink link = FushiPairLink(
      hostId: 'HOST-1',
      deviceName: 'My PC 日本語',
      fingerprint: 'aa:bb:cc',
      ticketId: 'tid',
      ticketSecret: 'sec.ret',
      addresses: <InterconnectHostAddress>[
        InterconnectHostAddress(
          url: 'http://192.168.1.5:38765',
          kind: InterconnectAddressKind.lan,
        ),
        InterconnectHostAddress(
          url: 'http://[2408::5]:38765',
          kind: InterconnectAddressKind.ipv6,
        ),
        InterconnectHostAddress(
          url: 'p2p://node?x=1&y=2',
          kind: InterconnectAddressKind.p2p,
        ),
      ],
    );

    test('往返无损（含中文名、v6 方括号、带 & 的地址、带点的 secret）', () {
      final FushiPairLink? back = FushiPairLink.tryParse(link.toUri());
      expect(back, isNotNull);
      expect(back!.hostId, 'HOST-1');
      expect(back.deviceName, 'My PC 日本語');
      expect(back.fingerprint, 'aa:bb:cc');
      expect(back.ticketId, 'tid');
      expect(back.ticketSecret, 'sec.ret');
      expect(back.addresses, link.addresses);
    });

    test('NFC 贴纸：withoutTicket 绝不带 k', () {
      final String uri = link.withoutTicket().toUri();
      expect(uri.contains('k='), isFalse);
      expect(FushiPairLink.tryParse(uri)!.hasTicket, isFalse);
    });

    test('不是配对链接 / 缺 hostId / 没有可用地址 → null', () {
      expect(FushiPairLink.tryParse('fushi://lookup?word=x'), isNull);
      expect(FushiPairLink.tryParse('https://pair?h=x'), isNull);
      expect(FushiPairLink.tryParse('fushi://pair?a=lan~http://x:1'), isNull);
      expect(
        FushiPairLink.tryParse('fushi://pair?h=H&a=quantum~http://x:1'),
        isNull,
      );
      expect(FushiPairLink.tryParse(null), isNull);
    });
  });

  group('票据配对（真 host）', () {
    late Directory dir;
    late FushiSyncServer server;
    late int approvals;
    late int pinGenerated;
    late DateTime now;

    setUp(() async {
      approvals = 0;
      pinGenerated = 0;
      now = DateTime(2026, 9, 28, 12);
      dir = await Directory.systemTemp.createTemp('fushi_link_pair_test');
      server =
          FushiSyncServer(
              syncDataDir: dir.path,
              port: 0,
              token: 'shared-token',
              allowLan: true,
              deviceName: 'Host PC',
              now: () => now,
            )
            ..hostId = 'HOST-1'
            ..onPairRequest = ((FushiPairRequest r) async {
              approvals++;
              return true;
            })
            ..onPairPinGenerated = ((FushiPairSession s) {
              pinGenerated++;
              return '123456';
            })
            // LAN 也要 PIN：这样「零审批、零 PIN 配上」只可能来自票据路径——
            // 否则 127.0.0.1 会走 LAN 免 PIN，测试对票据是否生效毫无区分度。
            ..lanRequiresPinProvider = (() async => true)
            ..interfaceLister = (() async => <NetworkInterface>[]);
      await server.start();
    });

    tearDown(() async {
      await server.stop();
      await cleanupTempDir(dir);
    });

    Future<http.Response> start(String? ticket) => http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'clientNonce': 'cn',
        if (ticket != null) 'ticket': ticket,
      }),
    );

    Future<http.Response> confirm(
      String sessionId,
      String hostNonce,
      String secret,
    ) => http.post(
      Uri.parse('http://127.0.0.1:${server.port}/api/pair/v2/confirm'),
      headers: <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(<String, String>{
        'sessionId': sessionId,
        'pinProof': FushiPairingProtocol.computePinProof(
          pin: secret,
          clientNonce: 'cn',
          hostNonce: hostNonce,
        ),
      }),
    );

    test('有效票据：免审批、免屏显 PIN，secret 代 PIN 过 confirm，用后作废', () async {
      final FushiPairTicket ticket = server.issuePairTicket();
      final Map<String, dynamic> body =
          jsonDecode((await start(ticket.id)).body) as Map<String, dynamic>;
      expect(body['pinRequired'], isTrue);
      final http.Response ok = await confirm(
        body['sessionId'] as String,
        body['hostNonce'] as String,
        ticket.secret,
      );
      expect(ok.statusCode, 200);
      expect(approvals, 0, reason: '打开二维码即已批准');
      expect(pinGenerated, 0, reason: '票据会话不生成屏显 PIN');

      final http.Response again = await start(ticket.id);
      expect(again.statusCode, 403, reason: '一次性：配成一台即作废');
      expect(jsonDecode(again.body)['reason'], 'expired');
    });

    test('一票一会话：建会话即消耗，拍到二维码的人无法预开会话', () async {
      final FushiPairTicket ticket = server.issuePairTicket();
      final http.Response first = await start(ticket.id);
      expect(first.statusCode, 200);
      final http.Response second = await start(ticket.id);
      expect(second.statusCode, 403);
      expect(jsonDecode(second.body)['reason'], 'expired');
    });

    test('关闭二维码：已凭票据开出、未 confirm 的会话一并作废', () async {
      final FushiPairTicket ticket = server.issuePairTicket();
      final Map<String, dynamic> body =
          jsonDecode((await start(ticket.id)).body) as Map<String, dynamic>;
      server.revokePairTicket();
      final http.Response late = await confirm(
        body['sessionId'] as String,
        body['hostNonce'] as String,
        ticket.secret,
      );
      expect(late.statusCode, 403);
      expect(approvals, 0);
    });

    test('错误 secret → 401，与 PIN 错同一条路', () async {
      final FushiPairTicket ticket = server.issuePairTicket();
      final Map<String, dynamic> body =
          jsonDecode((await start(ticket.id)).body) as Map<String, dynamic>;
      final http.Response bad = await confirm(
        body['sessionId'] as String,
        body['hostNonce'] as String,
        'wrong',
      );
      expect(bad.statusCode, 401);
    });

    test('过期 / 被刷新掉的票据 → expired（不回落到弹审批的普通流程）', () async {
      final FushiPairTicket old = server.issuePairTicket();
      server.issuePairTicket(); // 重新打开二维码：旧票据作废。
      final http.Response stale = await start(old.id);
      expect(stale.statusCode, 403);
      expect(jsonDecode(stale.body)['reason'], 'expired');

      final FushiPairTicket t = server.issuePairTicket(
        ttl: const Duration(minutes: 5),
      );
      now = now.add(const Duration(minutes: 6));
      final http.Response expired = await start(t.id);
      expect(expired.statusCode, 403);
      expect(jsonDecode(expired.body)['reason'], 'expired');
      expect(approvals, 0);
    });

    test('端到端：链接 → 跳过死地址 → 零审批配对；明文地址不记为 learned', () async {
      final FushiDatabase db = FushiDatabase(dir.path);
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      final String live = 'http://127.0.0.1:${server.port}';
      final FushiPairLink link = FushiPairLink(
        hostId: 'HOST-1',
        deviceName: 'Host PC',
        ticketId: server.issuePairTicket().id,
        ticketSecret: null,
        addresses: <InterconnectHostAddress>[
          // 死地址排前面：选路必须跳过它而不是卡在它上面。
          const InterconnectHostAddress(
            url: 'http://127.0.0.1:1',
            kind: InterconnectAddressKind.lan,
          ),
          InterconnectHostAddress(
            url: live,
            kind: InterconnectAddressKind.ipv6,
          ),
        ],
      );
      // 用真 secret 组一条完整链接。
      final FushiPairTicket ticket = server.issuePairTicket();
      final FushiPairLink full = FushiPairLink.tryParse(
        FushiPairLink(
          hostId: link.hostId,
          deviceName: link.deviceName,
          ticketId: ticket.id,
          ticketSecret: ticket.secret,
          addresses: link.addresses,
        ).toUri(),
      )!;

      final InterconnectLinkPairingResult result =
          await pairWithInterconnectLink(
            repo: repo,
            link: full,
            localDeviceName: 'Phone',
            pinProvider: () async => fail('带票据的链接不该再问 PIN'),
          );

      expect(result, isA<InterconnectLinkPaired>());
      expect((result as InterconnectLinkPaired).baseUrl, live);
      expect(approvals, 0, reason: '票据路径不弹审批');
      expect(pinGenerated, 0);
      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      expect(urls.map((FushiClientUrl u) => u.url), <String>[live],
          reason: '死的明文地址不学（明文 learned 地址换网可能是别人的机器）');
      expect(urls.single.hostId, 'HOST-1');
      expect(
        urls.firstWhere((FushiClientUrl u) => u.url == live).learned,
        isFalse,
      );
      expect(
        urls.firstWhere((FushiClientUrl u) => u.url == live).token,
        isNotEmpty,
      );
      expect(await repo.isInterconnectEnabled(), isTrue);
      expect(interconnectPeerRepresentatives(urls).single.url, live);
    });

    test('恶意链接冒用已配对 host 的 hostId 但指纹不符 → 不并入那一组', () async {
      final FushiDatabase db = FushiDatabase(dir.path);
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      // 已配对的真 host：同一个 hostId，带证书指纹。
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(
          url: 'https://real.example',
          hostId: 'HOST-1',
          fingerprintSha256: 'aa:aa',
          token: 'real-token',
        ),
        FushiClientUrl(
          url: 'https://10.0.0.2:1',
          hostId: 'HOST-1',
          learned: true,
          fingerprintSha256: 'aa:aa',
          token: 'real-token',
        ),
      ]);
      final FushiPairTicket ticket = server.issuePairTicket();
      final InterconnectLinkPairingResult result =
          await pairWithInterconnectLink(
            repo: repo,
            link: FushiPairLink(
              hostId: 'HOST-1', // 冒用
              fingerprint: 'bb:bb',
              ticketId: ticket.id,
              ticketSecret: ticket.secret,
              addresses: <InterconnectHostAddress>[
                InterconnectHostAddress(
                  url: 'http://127.0.0.1:${server.port}',
                  kind: InterconnectAddressKind.lan,
                ),
                const InterconnectHostAddress(
                  url: 'https://evil.example',
                  kind: InterconnectAddressKind.public,
                ),
              ],
            ),
            localDeviceName: 'Phone',
            pinProvider: () async => null,
          );
      expect(result, isA<InterconnectLinkPaired>());
      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      expect(
        urls
            .where((FushiClientUrl u) => u.hostId == 'HOST-1')
            .map((FushiClientUrl u) => u.url),
        <String>['https://real.example', 'https://10.0.0.2:1'],
        reason: '真 host 的组原封不动：没被删地址，也没混进冒名者的地址',
      );
      expect(urls.any((FushiClientUrl u) => u.url == 'https://evil.example'),
          isFalse);
    });

    test('链接里的 host 身份与实际应答不符 → unreachable（不向冒名者配对）', () async {
      final FushiDatabase db = FushiDatabase(dir.path);
      addTearDown(db.close);
      final InterconnectLinkPairingResult result =
          await pairWithInterconnectLink(
            repo: SyncRepository(db),
            link: FushiPairLink(
              hostId: 'SOMEONE-ELSE',
              addresses: <InterconnectHostAddress>[
                InterconnectHostAddress(
                  url: 'http://127.0.0.1:${server.port}',
                  kind: InterconnectAddressKind.lan,
                ),
              ],
            ),
            localDeviceName: 'Phone',
            pinProvider: () async => null,
          );
      expect(result, isA<InterconnectLinkPairingFailed>());
      expect((result as InterconnectLinkPairingFailed).reason, 'unreachable');
    });
  });
}
