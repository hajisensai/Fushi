import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

  // BUG-1738：指令函数必须对全部可持久化输入收敛，永不抛。设置页逐键落库，
  // custom 模式下半截/空输入曾经抛 FormatException，沿 createDownloadHttpClient
  // 炸进 reloadVideoDownloadPipelineRuntime，把下载管线永久杀死（UI 表现为
  // 「原下载后端当前离线」「请先配置下载后端」+ 任务罢工）。非法输入 fail-open
  // 落 DIRECT，与 BUG-1538「误套黑洞代理比误直连更糟」同一纪律。
  group('BUG-1738 非法 custom 代理 fail-open 而不是杀管线', () {
    test('invalid custom proxy degrades to DIRECT instead of throwing', () {
      expect(
        fixedDownloadProxyDirective(
          const DownloadNetworkProxyConfig(
            mode: DownloadNetworkProxyMode.custom,
            customProxy: 'not-a-proxy',
          ),
        ),
        'DIRECT',
      );
    });

    test('empty custom proxy (fresh switch to custom) degrades to DIRECT', () {
      expect(
        fixedDownloadProxyDirective(
          const DownloadNetworkProxyConfig(
            mode: DownloadNetworkProxyMode.custom,
            customProxy: '',
          ),
        ),
        'DIRECT',
      );
    });

    test('half-typed proxy (per-keystroke persistence) degrades to DIRECT', () {
      // 用户逐键输入 127.0.0.1:7890 的中间态全部非法，任何一个都不许抛。
      for (final String partial in <String>[
        '1',
        '127.0.0.1',
        '127.0.0.1:',
      ]) {
        expect(
          fixedDownloadProxyDirective(
            DownloadNetworkProxyConfig(
              mode: DownloadNetworkProxyMode.custom,
              customProxy: partial,
            ),
          ),
          'DIRECT',
          reason: 'partial input "$partial" must fail open',
        );
      }
    });

    test('buildDownloadHttpClient never throws for any mode/config', () async {
      for (final DownloadNetworkProxyConfig config
          in const <DownloadNetworkProxyConfig>[
        DownloadNetworkProxyConfig(),
        DownloadNetworkProxyConfig(mode: DownloadNetworkProxyMode.auto),
        DownloadNetworkProxyConfig(
          mode: DownloadNetworkProxyMode.custom,
          customProxy: '',
        ),
        DownloadNetworkProxyConfig(
          mode: DownloadNetworkProxyMode.custom,
          customProxy: 'not-a-proxy',
        ),
        DownloadNetworkProxyConfig(
          mode: DownloadNetworkProxyMode.custom,
          customProxy: '127.0.0.1:34151',
        ),
      ]) {
        final http.Client client = await buildDownloadHttpClient(config);
        client.close();
      }
    });
  });
}
