import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/metadata/video_scrape_error_text.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';

/// 「视频刮削资料正在清理」从写死的中文 `StateError` 改成类型化错误 + 本地化文案
/// （gap-scanner-11 遗留）。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('类型化错误出本地化文案，不露 `Bad state:` 与写死的中文', () {
    final VideoScrapeMaintenanceActiveError error =
        VideoScrapeMaintenanceActiveError();
    expect(
      videoScrapeMaintenanceText(error),
      t.video_scrape_maintenance_active,
    );
    expect(videoScrapeErrorText(error), t.video_scrape_maintenance_active);
    expect(videoScrapeErrorText(error), isNot(contains('Bad state')));
    expect(videoScrapeErrorText(error), isNot(contains('视频刮削资料')));
  });

  test('其它错误：maintenance 文案不冒领，交回调用方 / 原样', () {
    expect(videoScrapeMaintenanceText(StateError('other')), isNull);
    expect(videoScrapeMaintenanceText(null), isNull);
    expect(
      videoScrapeErrorText(StateError('other')),
      StateError('other').toString(),
    );
  });

  test('app 与引擎里不再有写死中文串的 StateError（一律抛类型化错误）', () {
    final List<String> offenders = <String>[];
    for (final String root in <String>['lib', '../packages/fushi_engine/lib']) {
      for (final FileSystemEntity entity in Directory(
        root,
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('.g.dart')) continue;
        final String source = entity.readAsStringSync();
        if (source.contains("StateError('视频刮削资料正在清理')")) {
          offenders.add(entity.path);
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: '写死的中文串到界面上就是 `Bad state: 视频刮削资料正在清理`，不随语言变',
    );
  });
}
