import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/leaderboard/install_identity.dart';
import 'package:fushi_engine/leaderboard/leaderboard_identity.dart';
import 'package:test/test.dart';

final RegExp _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  group('installId 推导', () {
    test('同一机器标识 → 同一 installId / 公钥（重装不变）', () {
      final InstallIdentity a = InstallIdentity.fromMachineId(
        '4c4c4544-0042-3510-8050-b4c04f4e3732',
      );
      final InstallIdentity b = InstallIdentity.fromMachineId(
        '4c4c4544-0042-3510-8050-b4c04f4e3732',
      );
      expect(a.installId, b.installId);
      expect(a.pubkeyBase64Url, b.pubkeyBase64Url);
      expect(a.installId, matches(_uuidV4));
    });

    test('大小写 / 首尾空白不影响结果（macOS 大写、Windows 小写）', () {
      expect(
        InstallIdentity.fromMachineId(
          '  4C4C4544-0042-3510-8050-B4C04F4E3732\n',
        ).installId,
        InstallIdentity.fromMachineId(
          '4c4c4544-0042-3510-8050-b4c04f4e3732',
        ).installId,
      );
    });

    test('不同机器标识 → 不同 installId', () {
      final Set<String> ids = <String>{
        for (int i = 0; i < 20; i++)
          InstallIdentity.fromMachineId('machine-id-number-$i').installId,
      };
      expect(ids, hasLength(20));
    });

    test('随机种子回退与同串机器标识互不相撞（域分隔）', () {
      expect(
        InstallIdentity.fromLocalRandom('abcdef0123456789').installId,
        isNot(InstallIdentity.fromMachineId('abcdef0123456789').installId),
      );
    });

    test('installId 就是公钥指纹', () {
      final InstallIdentity a = InstallIdentity.fromMachineId(
        'some-machine-identifier',
      );
      expect(installIdFromSpki(a.spki), a.installId);
    });

    test('不可用的机器标识被拒（空 / 过短 / 全同字符 / 已知共用值）', () {
      for (final String bad in <String>[
        '',
        '   ',
        'abc',
        '00000000-0000-0000-0000-000000000000',
        'ffffffffffffffff',
        'uninitialized',
        '9774d56d682e549c',
      ]) {
        expect(isUsableInstallMachineId(bad), isFalse, reason: bad);
        expect(
          () => InstallIdentity.fromMachineId(bad),
          throwsArgumentError,
          reason: bad,
        );
      }
      expect(isUsableInstallMachineId('9774d56d682e549d'), isTrue);
    });

    test('私钥标量落在 [1, n-1]：全 0 / 全 FF seed 都能推出合法钥匙', () {
      for (final int fill in <int>[0x00, 0xff]) {
        final Uint8List seed = Uint8List(32)..fillRange(0, 32, fill);
        expect(() => InstallIdentity.fromSeed(seed).installId, returnsNormally);
      }
      expect(
        () => installPrivateKeyFromSeed(Uint8List(31)),
        throwsArgumentError,
      );
    });
  });

  group('工作量证明', () {
    test('难度常量与服务端一致', () {
      expect(kInstallPowBits, 18);
    });

    test('solve 出的 nonce 通过校验；别的 id / 篡改 nonce 不通过', () {
      const String id = '0f8fad5b-d9cb-469f-a165-70867728950e';
      final String nonce = solveInstallPow(id, bits: 10);
      expect(installPowValid(id, nonce, bits: 10), isTrue);
      expect(
        installPowValid(
          '7c9e6679-7425-40de-944b-e07fc1f90ae7',
          nonce,
          bits: 24,
        ),
        isFalse,
      );
      expect(installPowValid(id, 'x$nonce', bits: 10), isFalse);
      expect(installPowValid(id, '', bits: 10), isFalse);
    });

    test('后台 isolate 版本与同步版本结果一致', () async {
      const String id = '0f8fad5b-d9cb-469f-a165-70867728950e';
      expect(
        await solveInstallPowInBackground(id, bits: 8),
        solveInstallPow(id, bits: 8),
      );
    });
  });

  group('请求证明头', () {
    test('签名覆盖方法 / 路径 / 时刻 / 请求体，带域前缀', () {
      final InstallIdentity id = InstallIdentity.fromMachineId(
        'header-test-machine',
      );
      final InstallAttestation att = InstallAttestation(id, '42');
      final List<int> body = utf8.encode('{"a":1}');
      final Map<String, String> h = att.headersFor(
        'POST',
        '/v1/ping',
        1792238400000,
        body,
      );
      expect(h[kInstallKeyHeader], id.pubkeyBase64Url);
      expect(h[kInstallTimeHeader], '1792238400000');
      expect(h[kInstallPowHeader], '42');
      final String msg = InstallIdentity.signingString(
        'POST',
        '/v1/ping',
        1792238400000,
        body,
      );
      expect(msg, startsWith(kInstallSignaturePrefix));
      expect(
        LeaderboardIdentity.verify(id.spki, msg, h[kInstallSigHeader]!),
        isTrue,
      );
      // 换请求体 / 路径就验不过。
      expect(
        LeaderboardIdentity.verify(
          id.spki,
          InstallIdentity.signingString(
            'POST',
            '/v1/ping',
            1792238400000,
            utf8.encode('{"a":2}'),
          ),
          h[kInstallSigHeader]!,
        ),
        isFalse,
      );
      // 去掉域前缀（当账户签名串用）也验不过：签名不能跨用途挪用。
      expect(
        LeaderboardIdentity.verify(
          id.spki,
          msg.substring(kInstallSignaturePrefix.length),
          h[kInstallSigHeader]!,
        ),
        isFalse,
      );
    });
  });

  test('跨语言向量：与 services/leaderboard/test/vectors_install 逐字节一致', () {
    final File f = File(
      '../../services/leaderboard/test/vectors_install/dart-install.json',
    );
    final Map<String, dynamic> v =
        (jsonDecode(f.readAsStringSync()) as Map<Object?, Object?>)
            .cast<String, dynamic>();
    final InstallIdentity id = InstallIdentity.fromMachineId(
      v['machineId'] as String,
    );
    expect(id.installId, v['installId']);
    expect(id.pubkeyBase64Url, v['pubkey']);
    expect(installPowValid(id.installId, v['powNonce'] as String), isTrue);
    // RFC 6979 确定性签名：同钥匙同消息签名恒定，重签必须与向量一致。
    final Map<String, String> h =
        InstallAttestation(id, v['powNonce'] as String).headersFor(
          v['method'] as String,
          v['path'] as String,
          v['time'] as int,
          utf8.encode(v['body'] as String),
        );
    expect(h[kInstallSigHeader], v['signature']);
  });
}
