import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/torrent/download_network_proxy.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  // BUG-1538：下载域默认不走代理。未设置/未知值一律落 direct；
  // 只有用户显式存过 'auto'/'custom' 才套代理。
  group('BUG-1538 下载域默认 direct', () {
    test('unset stored mode defaults to direct', () {
      expect(
        DownloadNetworkProxyMode.parse(null),
        DownloadNetworkProxyMode.direct,
      );
      expect(
        DownloadNetworkProxyMode.parse(''),
        DownloadNetworkProxyMode.direct,
      );
    });

    test('unknown stored mode fails safe to direct, not proxy', () {
      // 未知值套 auto 意味着「新版本写的模式名被旧版本读到」时静默走系统代理；
      // direct 的失败模式（连不上→10s 报错重试）比黑洞代理温和，故落 direct。
      expect(
        DownloadNetworkProxyMode.parse('future-value'),
        DownloadNetworkProxyMode.direct,
      );
    });

    test('explicit auto/custom opt-in is preserved (never break userspace)',
        () {
      expect(
        DownloadNetworkProxyMode.parse('auto'),
        DownloadNetworkProxyMode.auto,
      );
      expect(
        DownloadNetworkProxyMode.parse('custom'),
        DownloadNetworkProxyMode.custom,
      );
    });

    test('default config emits DIRECT', () {
      expect(
        fixedDownloadProxyDirective(const DownloadNetworkProxyConfig()),
        'DIRECT',
      );
    });

    test('fresh preferences resolve to direct download proxy mode', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final PreferencesRepository repo = PreferencesRepository(db);
      await repo.loadFromDb();
      expect(repo.downloadNetworkProxyMode, 'direct');
      expect(
        DownloadNetworkProxyMode.parse(repo.downloadNetworkProxyMode),
        DownloadNetworkProxyMode.direct,
      );
      // 已保存 'auto' 的老用户不被默认值变更覆盖。
      await repo.setDownloadNetworkProxyMode('auto');
      expect(
        DownloadNetworkProxyMode.parse(repo.downloadNetworkProxyMode),
        DownloadNetworkProxyMode.auto,
      );
    });
  });

  test('direct mode always emits DIRECT', () {
    expect(
      fixedDownloadProxyDirective(
        const DownloadNetworkProxyConfig(
          mode: DownloadNetworkProxyMode.direct,
        ),
      ),
      'DIRECT',
    );
  });

  test('custom mode normalizes a scheme and emits its proxy', () {
    expect(
      fixedDownloadProxyDirective(
        const DownloadNetworkProxyConfig(
          mode: DownloadNetworkProxyMode.custom,
          customProxy: 'http://127.0.0.1:34151',
        ),
      ),
      'PROXY 127.0.0.1:34151',
    );
  });

  test('invalid custom proxy fails instead of silently changing policy', () {
    expect(
      () => fixedDownloadProxyDirective(
        const DownloadNetworkProxyConfig(
          mode: DownloadNetworkProxyMode.custom,
          customProxy: 'not-a-proxy',
        ),
      ),
      throwsFormatException,
    );
  });
}
