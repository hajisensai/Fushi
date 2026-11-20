/// BUG-4985：`fushi_server admin reset-tls` 是旧部署换掉 Chrome 拒收证书的唯一入口
/// （`loadOrCreate` 对已落盘的证书不自动重签）。用固定向量里的旧版证书当磁盘现状，
/// 跑真实 CLI，断言证书被换成新格式、指纹变了。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:fushi_server/src/cli.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _legacyCertificatePem() {
  final Map<String, Object?> vectors =
      jsonDecode(
            File(
              p.join(
                '..',
                'fushi_compute',
                'test',
                'crypto',
                'crypto_vectors_v2.json',
              ),
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final Map<String, Object?> tls =
      vectors['tls_self_signed']! as Map<String, Object?>;
  return tls['certificate_pem_example']! as String;
}

void main() {
  test('admin reset-tls 把旧格式证书重签成 Chrome 可接受的新证书', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'fushi_reset_tls_',
    );
    addTearDown(() => tmp.delete(recursive: true));
    final String dataDir = p.join(tmp.path, 'data');
    final File config = File(p.join(tmp.path, 'fushi_server.yaml'));
    await ServerConfig.defaults(dataDir: dataDir).save(config);

    final String legacyPem = _legacyCertificatePem();
    expect(
      FushiTlsIdentityStore.isChromeRejectedLegacyCertificate(legacyPem),
      isTrue,
    );
    final Directory tlsDir = Directory(
      p.join(ServerPaths(dataDir).syncData.path, 'sync-tls'),
    );
    await tlsDir.create(recursive: true);
    final File cert = File(p.join(tlsDir.path, 'identity-cert.pem'));
    await cert.writeAsString(legacyPem);
    await File(
      p.join(tlsDir.path, 'identity-key.pem'),
    ).writeAsString('legacy key');

    expect(
      await runFushiServerCli(<String>[
        'admin',
        'reset-tls',
        '--config',
        config.path,
      ]),
      0,
    );

    final String reissued = await cert.readAsString();
    expect(
      FushiTlsIdentityStore.isChromeRejectedLegacyCertificate(reissued),
      isFalse,
    );
    expect(
      FushiTlsIdentityStore.fingerprintOf(reissued),
      isNot(FushiTlsIdentityStore.fingerprintOf(legacyPem)),
    );
    // 之后的 serve 加载的就是这张新证书。
    final FushiTlsIdentity loaded = await FushiTlsIdentityStore(
      dataDir: ServerPaths(dataDir).syncData.path,
    ).loadOrCreate();
    expect(loaded.certificatePem, reissued);
    expect(loaded.privateKeyPem, isNot('legacy key'));
  });

  test('admin 未知子命令仍是用法错误 64', () async {
    final Directory tmp = await Directory.systemTemp.createTemp(
      'fushi_reset_tls_',
    );
    addTearDown(() => tmp.delete(recursive: true));
    final File config = File(p.join(tmp.path, 'fushi_server.yaml'));
    await ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).save(config);
    expect(
      await runFushiServerCli(<String>[
        'admin',
        'no-such',
        '--config',
        config.path,
      ]),
      64,
    );
  });
}
