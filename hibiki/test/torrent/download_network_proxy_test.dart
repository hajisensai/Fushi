import 'package:flutter_test/flutter_test.dart';

import 'package:hibiki/src/media/torrent/download_network_proxy.dart';

void main() {
  test('unknown stored mode remains backward-compatible with auto', () {
    expect(
      DownloadNetworkProxyMode.parse('future-value'),
      DownloadNetworkProxyMode.auto,
    );
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
