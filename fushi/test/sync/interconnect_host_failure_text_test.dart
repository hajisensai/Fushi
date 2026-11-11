/// 互联能力探测失败原因 → 界面提示的消费方映射（BUG-4404 评审 tests-5 / correctness-2）。
///
/// 发现页下载 / 订阅入口打开前的 toast 只在「本机跑不了、远端是唯一出路」时说：
/// 本机有下载管线时，一台只配对来同步、没开代下载的 host（unsupported）不该每次都
/// 弹「主机没有提供这项功能」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_execution_target.dart';
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_host_failure_text.dart';

const InterconnectHostRef _pc = InterconnectHostRef.legacyUrl(
  'http://10.0.0.1:8080',
);
const InterconnectHostRef _phone = InterconnectHostRef.legacyUrl(
  'http://10.0.0.2:8080',
);

InterconnectCapabilityOutcome<String> _down(
  InterconnectHostRef host,
  String label,
  InterconnectHostFailure failure,
) => InterconnectCapabilityUnavailable<String>(
  host: host,
  label: label,
  failure: failure,
);

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('值得说的原因：凭据 / 证书 / 能力 / 配对；连不上与 HTTP 错误不说', () {
    expect(
      <InterconnectHostFailure, bool>{
        for (final InterconnectHostFailure f in InterconnectHostFailure.values)
          f: interconnectHostFailureWorthTelling(f),
      },
      <InterconnectHostFailure, bool>{
        InterconnectHostFailure.notPaired: true,
        InterconnectHostFailure.unreachable: false,
        InterconnectHostFailure.authRejected: true,
        InterconnectHostFailure.certificateMismatch: true,
        InterconnectHostFailure.unsupported: true,
        InterconnectHostFailure.httpError: false,
      },
    );
  });

  test('第一条值得说的失败带设备名；跳过连不上的', () {
    final String? line = interconnectFirstTellableFailureLine<String>(
      <InterconnectCapabilityOutcome<String>>[
        _down(_pc, 'PC', InterconnectHostFailure.unreachable),
        _down(_phone, 'Phone', InterconnectHostFailure.authRejected),
      ],
    );
    expect(
      line,
      interconnectHostFailureLine(
        InterconnectHostFailure.authRejected,
        device: 'Phone',
      ),
    );
    expect(
      interconnectFirstTellableFailureLine<String>(
        <InterconnectCapabilityOutcome<String>>[
          _down(_pc, 'PC', InterconnectHostFailure.unreachable),
        ],
      ),
      isNull,
    );
  });

  group('发现页入口：只在远端是唯一出路时说', () {
    final List<InterconnectCapabilityOutcome<String>> syncOnlyHost =
        <InterconnectCapabilityOutcome<String>>[
          _down(_pc, 'PC', InterconnectHostFailure.unsupported),
        ];

    test('本机能下：已配对 host 不提供代下载也不弹（修复前每次都弹）', () {
      expect(
        interconnectRemoteOnlyFailureNotice<String>(
          syncOnlyHost,
          localRunnable: true,
        ),
        isNull,
      );
    });

    test('本机跑不了、一台可用 host 都没有：说出第一条原因', () {
      expect(
        interconnectRemoteOnlyFailureNotice<String>(
          syncOnlyHost,
          localRunnable: false,
        ),
        interconnectHostFailureLine(
          InterconnectHostFailure.unsupported,
          device: 'PC',
        ),
      );
    });

    test('另有一台 host 可用：不说', () {
      expect(
        interconnectRemoteOnlyFailureNotice<String>(
          <InterconnectCapabilityOutcome<String>>[
            ...syncOnlyHost,
            const InterconnectCapabilityAvailable<String>(
              host: _phone,
              label: 'Phone',
              target: 'ok',
            ),
          ],
          localRunnable: false,
        ),
        isNull,
      );
    });
  });

  test('下载执行设备的提示：能动手解决的原因带设备名，连不上沿用原文案', () {
    expect(
      downloadExecutionUnreachableMessage(
        const DownloadExecutionUnreachable(
          url: 'http://10.0.0.1:8080',
          deviceName: 'PC',
          failure: InterconnectHostFailure.unsupported,
        ),
      ),
      interconnectHostFailureLine(
        InterconnectHostFailure.unsupported,
        device: 'PC',
      ),
    );
    expect(
      downloadExecutionUnreachableMessage(
        const DownloadExecutionUnreachable(url: 'http://10.0.0.1:8080'),
      ),
      t.download_execution_host_unreachable,
    );
  });
}
