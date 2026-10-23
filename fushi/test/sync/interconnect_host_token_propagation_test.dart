import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';

/// 53NT7G_tSO：host 按设备只认一份 per-peer token（重新配对即作废旧的）。经某一条
/// 地址重新配对后，同一台 host 的其余地址（内网 / 外网 / IPv6）必须拿到新 token，
/// 否则一律 401——用户看到的就是「内网和外网 token 不同，且无法单独配置」。
const String _fp = 'aa:bb:cc';

FushiClientUrl _lan({String? token = 'old'}) => FushiClientUrl(
  url: 'https://192.168.1.30:38765',
  fingerprintSha256: _fp,
  hostId: 'host-1',
  token: token,
);

void main() {
  group('applyIssuedInterconnectToken', () {
    test('新 token 落到同一台 host 的全部地址', () {
      final List<FushiClientUrl> out = applyIssuedInterconnectToken(
        <FushiClientUrl>[
          _lan(),
          const FushiClientUrl(
            url: 'https://[fd00::1]:38765',
            fingerprintSha256: _fp,
            hostId: 'host-1',
            token: 'old',
            learned: true,
          ),
          const FushiClientUrl(
            url: 'https://other:38765',
            hostId: 'host-2',
            token: 'other-token',
          ),
        ],
        url: 'https://192.168.1.30:38765',
        token: 'new',
      );
      expect(out.map((FushiClientUrl u) => u.token), <String?>[
        'new',
        'new',
        'other-token',
      ]);
    });

    test('手动补的外网地址：指纹相同 → 归入该 host 组，整组换新 token', () {
      final List<FushiClientUrl> out = applyIssuedInterconnectToken(
        <FushiClientUrl>[
          _lan(),
          const FushiClientUrl(
            url: 'https://my.example.cn:38765',
            fingerprintSha256: _fp,
          ),
        ],
        url: 'https://my.example.cn:38765',
        token: 'new',
        hostId: 'host-1',
      );
      expect(out[1].hostId, 'host-1');
      expect(out.map((FushiClientUrl u) => u.token), <String?>['new', 'new']);
    });

    test('指纹对不上（冒充的 hostId）→ 不归组，只改配对的那一行', () {
      final List<FushiClientUrl> out = applyIssuedInterconnectToken(
        <FushiClientUrl>[
          _lan(),
          const FushiClientUrl(
            url: 'https://evil:38765',
            fingerprintSha256: 'ff:ff:ff',
          ),
        ],
        url: 'https://evil:38765',
        token: 'evil-token',
        hostId: 'host-1',
      );
      expect(out[1].hostId, isNull);
      expect(out[0].token, 'old', reason: '绝不能把 token 改到另一台机器的地址上');
      expect(out[1].token, 'evil-token');
    });

    test('url 不在列表里 → 原样返回', () {
      final List<FushiClientUrl> list = <FushiClientUrl>[_lan()];
      expect(
        applyIssuedInterconnectToken(list, url: 'https://x:1', token: 't'),
        same(list),
      );
    });
  });

  test('SyncRepository.setFushiClientTokenForUrl 按 host 同步 token', () async {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      _lan(),
      const FushiClientUrl(
        url: 'https://my.example.cn:38765',
        fingerprintSha256: _fp,
      ),
    ]);
    await repo.setFushiClientTokenForUrl(
      'https://my.example.cn:38765',
      'new',
      hostId: 'host-1',
    );
    final List<FushiClientUrl> stored = await repo.getFushiClientUrls();
    expect(stored.map((FushiClientUrl u) => u.token), <String?>['new', 'new']);
    expect(await repo.getFushiClientToken(), 'new');
  });

  test('地址学习：锚点（刚用自己的 token 鉴权成功）把同组旧 token 换新', () {
    final List<FushiClientUrl> out = mergeLearnedHostAddresses(
      <FushiClientUrl>[
        _lan(),
        const FushiClientUrl(
          url: 'https://my.example.cn:38765',
          fingerprintSha256: _fp,
          hostId: 'host-1',
          token: 'fresh',
        ),
      ],
      anchorUrl: 'https://my.example.cn:38765',
      hostId: 'host-1',
      addresses: const <InterconnectHostAddress>[],
    );
    expect(out.map((FushiClientUrl u) => u.token), <String?>['fresh', 'fresh']);
  });

  group('interconnectTestFailureReason', () {
    test('凭据被拒 → 说重新配对，而不是「连接失败」', () {
      expect(
        interconnectTestFailureReason(
          SyncAuthError(
            'Authentication failed',
            kind: SyncAuthFailureKind.pairingRejected,
          ),
          hasPinnedCertificate: true,
        ),
        t.sync_err_pairing_rejected,
      );
    });

    test('没记录证书的 https 地址自签校验失败 → 指向这一行的重新配对', () {
      final SyncBackendError e = SyncBackendError(
        'Connection failed: ${const HandshakeException('Handshake error in '
        'client (OS Error: CERTIFICATE_VERIFY_FAILED: self signed '
        'certificate)')}',
      );
      expect(
        interconnectTestFailureReason(e, hasPinnedCertificate: false),
        t.interconnect_peer_certificate_unpinned,
      );
      expect(
        interconnectTestFailureReason(e, hasPinnedCertificate: true),
        t.sync_pair_tls_failed,
      );
    });
  });
}
