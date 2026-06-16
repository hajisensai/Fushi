import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source guard: the shared video bottom transport buttons keep tooltips and
/// i18n keys. media_kit controls are not stable in headless widget tests, so
/// this pins the page structure instead.
void main() {
  final File page = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  );
  final File baseI18n = File('lib/i18n/strings.i18n.json');
  final File generated = File('lib/i18n/strings.g.dart');

  late String src;
  late String i18nSrc;
  late String genSrc;
  setUpAll(() {
    expect(page.existsSync(), isTrue, reason: 'video page source must exist');
    expect(baseI18n.existsSync(), isTrue, reason: 'base i18n file must exist');
    expect(generated.existsSync(), isTrue, reason: 'strings.g.dart must exist');
    src = page.readAsStringSync();
    i18nSrc = baseI18n.readAsStringSync();
    genSrc = generated.readAsStringSync();
  });

  String bottomBarHelper() {
    final int start = src.indexOf('Widget _centeredBottomControlBar(');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'shared bottom bar helper must exist');
    final int end = src.indexOf('Widget _seekLabelButton(', start);
    expect(end, greaterThan(start),
        reason: '_centeredBottomControlBar should close normally');
    return src.substring(start, end);
  }

  String bottomSlotButtonBuilder() {
    final int start = src.indexOf('Widget _buildBottomSlotButton(');
    expect(start, greaterThanOrEqualTo(0),
        reason: 'bottom slot button builder must exist');
    final int end = src.indexOf('Widget _plainSlotButton(', start);
    expect(end, greaterThan(start),
        reason: '_buildBottomSlotButton should close normally');
    return src.substring(start, end);
  }

  const List<String> tooltipKeys = <String>[
    'video_bottom_seek_back',
    'video_bottom_prev_cue',
    'video_bottom_play_pause',
    'video_bottom_next_cue',
    'video_bottom_seek_forward',
  ];

  test('shared bottom transport buttons have tooltips', () {
    final String bar = bottomBarHelper();
    final String slotButtons = bottomSlotButtonBuilder();

    for (final String key in <String>[
      'video_bottom_prev_cue',
      'video_bottom_play_pause',
      'video_bottom_next_cue',
    ]) {
      expect(
        slotButtons.contains('Tooltip(') &&
            slotButtons.contains('message: t.$key'),
        isTrue,
        reason: 'bottom transport should include Tooltip(message: t.$key)',
      );
    }
    expect('Tooltip('.allMatches(slotButtons).length, greaterThanOrEqualTo(3),
        reason: 'previous/play/next cue buttons each need a Tooltip');
    expect(
      'tooltip: t.video_bottom_seek_back'.allMatches(slotButtons).length,
      1,
      reason: '-10s seek button should pass tooltip into _seekLabelButton',
    );
    expect(
      'tooltip: t.video_bottom_seek_forward'.allMatches(slotButtons).length,
      1,
      reason: '+10s seek button should pass tooltip into _seekLabelButton',
    );
    expect(bar.contains('VideoControlSlot.bottomCenter'), isTrue,
        reason: 'shared bar should render transport buttons from bottomCenter');
  });

  test('desktop and mobile bottom bars both delegate to the shared helper', () {
    expect(
      'Expanded(\n          child: _centeredBottomControlBar(controller, desktop: true)'
          .allMatches(src)
          .length,
      1,
      reason: 'desktop bottom bar should use the shared helper',
    );
    expect(
      'Expanded(\n          child: _centeredBottomControlBar(controller, desktop: false)'
          .allMatches(src)
          .length,
      1,
      reason: 'mobile bottom bar should use the shared helper',
    );
  });

  test('bottom tooltip i18n keys exist in base and generated files', () {
    for (final String key in tooltipKeys) {
      expect(i18nSrc.contains('"$key"'), isTrue,
          reason: 'strings.i18n.json missing key $key');
      expect(genSrc.contains('String get $key'), isTrue,
          reason: 'strings.g.dart missing getter $key');
    }
  });
}
