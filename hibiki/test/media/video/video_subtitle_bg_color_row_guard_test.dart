import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1059 zi wenti 1 fangan B yuanma shouwei: shezhi mianban (video quick
/// settings sheet) bixu you ziti beijing SE xuanze hang. Yonghu bao shezhi mianban
/// zhiyou butouming du huatiao, meiyou beijing SE kongjian. Ben shouwei suo ding:
/// _buildSubtitleDetail nei you jing AdaptiveSettingsPickerRow gua de beijing SE
/// xuanze hang, luo VideoSubtitleStyle.backgroundColor (jing copyWith +
/// resetBackgroundColor qingkong huifu moren hei). Cheng diao ze hong.
void main() {
  late String sheetSrc;
  late String styleSrc;
  setUpAll(() {
    String read(String p) =>
        File(p).readAsStringSync().replaceAll('\r\n', '\n');
    sheetSrc = read('lib/src/media/video/video_quick_settings_sheet.dart');
    styleSrc = read('lib/src/media/video/video_subtitle_style.dart');
  });

  test('sheet has a background-color picker row wired to backgroundColor', () {
    expect(sheetSrc.contains('video_setting_subtitle_bg_color'), isTrue,
        reason: 'must use the background-color i18n title key');
    expect(sheetSrc.contains('_bgColorPresets'), isTrue,
        reason: 'must build background-color presets');
    expect(sheetSrc.contains('AdaptiveSettingsPickerRow<int>('), isTrue,
        reason: 'must render the presets via a picker row');
    expect(
        sheetSrc.contains('backgroundColor: color') &&
            sheetSrc.contains('resetBackgroundColor: color == null'),
        isTrue,
        reason:
            'row must commit backgroundColor (null -> reset to default black)');
  });

  test('style default background is fixed translucent black, not theme surface',
      () {
    expect(styleSrc.contains('const Color kDefaultSubtitleBackgroundColor ='),
        isTrue,
        reason: 'must define kDefaultSubtitleBackgroundColor constant');
    expect(styleSrc.contains('bool resetBackgroundColor = false'), isTrue,
        reason: 'copyWith must support clearing backgroundColor to null');
  });
}
