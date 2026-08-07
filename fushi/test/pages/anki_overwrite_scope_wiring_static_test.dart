import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-614 静态守卫：把「覆写范围（latest/all）」两点改动的关键接线锁住，防止
/// 静默回退。覆盖：
///  - 点1：标签输入框归位到「默认标签」区（不再藏在「允许重复」组的门控里）。
///  - 点2：弹窗 lookup-time 探测在已制卡且非本会话最近时调 overwriteTargetNoteId，
///         拿到 id 灌进 rememberLatestMined → 更早的卡也能进 ✓↩ 覆写态。
///  - 点2 接线：webview/layer/各表面都把 onOverwriteTargetNoteId 透传到位。
///  - 持久化：AnkiSettings.overwriteScope 缺字段容错回 latest（不破旧用户）。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test(
      'point1: tags input lives in the default-tags section, not the '
      'allow-duplicates group', () {
    final src = read('lib/src/pages/implementations/anki_settings_page.dart');
    final int defaultSectionIdx = src.indexOf('t.anki_tag_default_section');
    final int dupSwitchIdx = src.indexOf('title: t.anki_allow_duplicates,');
    final int tagsInputIdx = src.indexOf('_buildTagsInput(settings, vm)');
    expect(defaultSectionIdx, greaterThanOrEqualTo(0));
    expect(dupSwitchIdx, greaterThanOrEqualTo(0));
    expect(tagsInputIdx, greaterThanOrEqualTo(0),
        reason: 'the tags input must still be rendered');
    // The tags input must appear AFTER the default-tags section title (i.e. it
    // moved into that section), not back up in the allow-duplicates group.
    expect(tagsInputIdx, greaterThan(defaultSectionIdx),
        reason: 'tags input must be inside the default-tags section');
  });

  test('point2: an overwrite-scope picker is wired to updateOverwriteScope',
      () {
    final src = read('lib/src/pages/implementations/anki_settings_page.dart');
    expect(src.contains('_buildOverwriteScopePicker('), isTrue,
        reason: 'a single-select overwrite-scope picker must exist');
    expect(src.contains('AnkiOverwriteScope.latest'), isTrue);
    expect(src.contains('AnkiOverwriteScope.all'), isTrue);
    expect(src.contains('vm.updateOverwriteScope('), isTrue,
        reason: 'the picker must persist the choice via the view model');
  });

  test('point2: popup.js promotes an earlier card via overwriteTargetNoteId',
      () {
    final js = read('assets/popup/popup.js');
    // The lookup-time detection must probe overwriteTargetNoteId and feed a real
    // id into rememberLatestMined so an earlier card can become the editable ✓↩.
    final int dupThenIdx = js
        .indexOf("callHandler('duplicateCheck', { expression, reading }).then");
    expect(dupThenIdx, greaterThanOrEqualTo(0));
    final int probeIdx = js.indexOf("'overwriteTargetNoteId'", dupThenIdx);
    expect(probeIdx, greaterThan(dupThenIdx),
        reason: 'lookup-time detection must probe overwriteTargetNoteId');
    final int rememberIdx = js.indexOf('rememberLatestMined(', probeIdx);
    expect(rememberIdx, greaterThan(probeIdx),
        reason: 'a real overwrite-target id must be promoted to the latest '
            'editable state');
    // And the probe must be gated on already being mined but NOT already latest
    // (avoid re-promoting / pointless calls).
    expect(
      js.contains('isDuplicate && !isLatestEditable(expression, reading)'),
      isTrue,
      reason: 'probe only an already-mined word that is not yet the latest',
    );
  });

  test(
      'point2: onOverwriteTargetNoteId is threaded through webview + layer + '
      'every popup surface', () {
    expect(
      read('lib/src/pages/implementations/dictionary_popup_webview.dart')
          .contains('onOverwriteTargetNoteId'),
      isTrue,
      reason:
          'webview must accept + register the overwriteTargetNoteId handler',
    );
    expect(
      read('lib/src/pages/implementations/dictionary_popup_webview.dart')
          .contains("handlerName: 'overwriteTargetNoteId'"),
      isTrue,
      reason: 'webview must register the JS handler',
    );
    expect(
      read('lib/src/pages/implementations/dictionary_popup_layer.dart')
          .contains('onOverwriteTargetNoteId: onOverwriteTargetNoteId'),
      isTrue,
      reason: 'layer must forward the callback to the webview',
    );
    // Surfaces that drive popups must supply the callback.
    expect(
      read('lib/src/pages/implementations/dictionary_page_mixin.dart')
          .contains('onOverwriteTargetNoteId: findOverwriteTargetNoteId'),
      isTrue,
      reason: 'dictionary surfaces (home dict / standalone popup) wire it',
    );
    expect(
      read('lib/src/pages/base_source_page.dart')
          .contains('onOverwriteTargetNoteId:'),
      isTrue,
      reason: 'reader / audiobook / video surfaces wire it',
    );
  });
}
