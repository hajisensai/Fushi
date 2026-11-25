import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';

// Apple 设计系统「iOS 档 / macOS 档」唯一判据（用户 2026-11-24：窄屏 = iOS，
// 宽屏 = macOS）：fushiAppleUsesMacMetrics、fushiAppleCompact、
// FushiAppleMetrics.of 三者必须一致——桌面平台窄窗不能出现「按钮 / 列表是 iOS
// 档、菜单 / chip / sheet 是 macOS 档」的混搭。

typedef _Probe = ({bool mac, bool compact, bool metricsDesktop});

Future<_Probe> _probe(
  WidgetTester tester, {
  required TargetPlatform platform,
  required double width,
}) async {
  late _Probe result;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: Size(width, 900)),
      child: Theme(
        data: ThemeData(platform: platform),
        child: Builder(
          builder: (BuildContext context) {
            result = (
              mac: fushiAppleUsesMacMetrics(context),
              compact: fushiAppleCompact(context),
              metricsDesktop: FushiAppleMetrics.of(context).desktop,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return result;
}

void main() {
  testWidgets('macOS 平台窄窗（430）是 iOS 档', (WidgetTester tester) async {
    final _Probe p = await _probe(
      tester,
      platform: TargetPlatform.macOS,
      width: 430,
    );
    expect(p, (mac: false, compact: false, metricsDesktop: false));
  });

  testWidgets('macOS 平台宽窗（1440）是 macOS 档', (WidgetTester tester) async {
    final _Probe p = await _probe(
      tester,
      platform: TargetPlatform.macOS,
      width: 1440,
    );
    expect(p, (mac: true, compact: true, metricsDesktop: true));
  });

  testWidgets('Windows 平台按同一宽度阈值分档', (WidgetTester tester) async {
    expect(
      await _probe(
        tester,
        platform: TargetPlatform.windows,
        width: kFushiAppleCompactMetricsWidth - 1,
      ),
      (mac: false, compact: false, metricsDesktop: false),
    );
    expect(
      await _probe(
        tester,
        platform: TargetPlatform.windows,
        width: kFushiAppleCompactMetricsWidth,
      ),
      (mac: true, compact: true, metricsDesktop: true),
    );
  });

  testWidgets('iOS 平台任何宽度都是 iOS 档', (WidgetTester tester) async {
    for (final double width in <double>[375, 834, 1440]) {
      final _Probe p = await _probe(
        tester,
        platform: TargetPlatform.iOS,
        width: width,
      );
      expect(p, (mac: false, compact: false, metricsDesktop: false));
    }
  });

  // macOS 档放大系数（用户 2026-11-24：Windows / Linux 上 macOS 档整体放大，
  // Mac 不变，iOS 档恒 1.0）：唯一判据 fushiAppleMacScale，度量对象同值。
  group('fushiAppleMacScale', () {
    Future<({double scale, double metricsScale, double title})> scaleProbe(
      WidgetTester tester, {
      required TargetPlatform platform,
      required double width,
    }) async {
      late ({double scale, double metricsScale, double title}) result;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: Size(width, 900)),
          child: Theme(
            data: ThemeData(platform: platform),
            child: Builder(
              builder: (BuildContext context) {
                final FushiAppleMetrics m = FushiAppleMetrics.of(context);
                result = (
                  scale: fushiAppleMacScale(context),
                  metricsScale: m.scale,
                  title: m.titleSize,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      return result;
    }

    testWidgets('macOS 宽窗（1440）系数 1.0，正文 13', (WidgetTester tester) async {
      expect(
        await scaleProbe(tester, platform: TargetPlatform.macOS, width: 1440),
        (scale: 1.0, metricsScale: 1.0, title: 13.0),
      );
    });

    testWidgets('Windows / Linux 宽窗（1440）放大', (WidgetTester tester) async {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        final ({double scale, double metricsScale, double title}) p =
            await scaleProbe(tester, platform: platform, width: 1440);
        expect(p.scale, kFushiAppleMacScaleNonMac);
        expect(p.metricsScale, kFushiAppleMacScaleNonMac);
        expect(p.title, closeTo(13 * kFushiAppleMacScaleNonMac, 1e-9));
      }
      expect(kFushiAppleMacScaleNonMac, greaterThan(1.0));
    });

    testWidgets('任何平台窄窗（430）系数 1.0', (WidgetTester tester) async {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.iOS,
        TargetPlatform.android,
      ]) {
        final ({double scale, double metricsScale, double title}) p =
            await scaleProbe(tester, platform: platform, width: 430);
        expect(p.scale, 1.0, reason: '$platform');
        expect(p.metricsScale, 1.0, reason: '$platform');
      }
    });
  });
}
