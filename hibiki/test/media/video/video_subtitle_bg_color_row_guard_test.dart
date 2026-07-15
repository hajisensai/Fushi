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

  test('sheet has a background-color COLOR PICKER row wired to backgroundColor',
      () {
    // Yonghu bao "hai you beijing": beijing SE yi cong gudinng yushe xialila
    // huancheng flutter_colorpicker de ColorPicker (dian hang kai duihuakuang qu
    // renyi SE). Ben shouwei suoding xin shixian -- tuihui yushe xialila ji hong.
    expect(sheetSrc.contains('video_setting_subtitle_bg_color'), isTrue,
        reason: 'must use the background-color i18n title key');
    expect(sheetSrc.contains('ColorPicker('), isTrue,
        reason: 'must render an actual color picker (not fixed presets)');
    expect(sheetSrc.contains('_buildSubtitleColorRow('), isTrue,
        reason: 'text/background colors share the color-picker row builder');
    expect(sheetSrc.contains('backgroundColor: c'), isTrue,
        reason: 'row must commit picked color to backgroundColor');
    // The old fixed-preset implementation must be fully gone.
    expect(sheetSrc.contains('_bgColorPresets'), isFalse,
        reason:
            'fixed background presets should be removed, replaced by picker');
    expect(sheetSrc.contains('_bgColorOptionIndex'), isFalse,
        reason: 'preset reverse-lookup index should be removed with the presets');
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
