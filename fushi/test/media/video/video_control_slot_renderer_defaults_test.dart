import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../pages/video_fushi_page_source_corpus.dart';

/// TODO-274 / TODO-312 phase 2: the control bar renderer + persistence are fully
/// on the 9-slot [VideoControlLayout]. This guard pins that the page renders from
/// the persisted layout slots (not the removed legacy 3-tier `buttonsFor(...)`
/// lookups). The old phase-1 `VideoControlLayout.fromLegacy(...)` equivalence
/// groups were dropped together with the legacy holder class; the lossless v1
/// migration is still covered by video_control_layout_test.dart.
///
/// The media_kit control bar itself can't render headless, so the structural
/// equivalence of the rendered tree is covered by the existing source guards
/// (video_bottom_bar_tooltips / video_play_center_seek_labels /
/// video_controls_customization / video_volume_and_settings_dedupe /
/// video_single_top_bar / video_mobile_controls_static). Here we lock the
/// data-layer mapping the renderer consumes.
void main() {
  group('page wires the slot renderer (data-driven, not legacy buttonsFor)',
      () {
    final File page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    );
    late String src;
    setUpAll(() {
      expect(page.existsSync(), isTrue);
      // TODO-590 batch11：_topBarSlotGroup(VideoControlSlot.topLeft/topRight 的调用随两套
      // controls 主题搬到 controls_theme.part.dart，读「合并语料」（主壳 + 全部 part）才能命中。
      src = readVideoFushiSource();
    });

    test('control bar reads the persisted VideoControlLayout (phase 2)', () {
      // Phase 2: _controlLayout is now a persisted field (the v2 source of
      // truth), loaded from AppModel.videoControlLayout, not derived read-only
      // from the legacy customization.
      expect(src,
          contains('ValueNotifier<VideoControlLayout> _controlLayoutNotifier'));
      expect(
          src,
          contains(
              'VideoControlLayout get _controlLayout => _controlLayoutNotifier.value'));
      expect(
          src,
          contains(
              '_controlLayoutNotifier.value = appModel.videoControlLayout'));
      // BUG-391 r4/r5 (TODO-771)：control bar 从
      // ValueListenableBuilder<VideoControlLayout> 改为 ListenableBuilder +
      // Listenable.merge（侧栏可见性也要重建 theme）；仍以持久化的
      // _controlLayoutNotifier 为权威，builder 内 .value 取值重建。
      expect(src, contains('Listenable.merge('));
      expect(
          src,
          contains(
              'final VideoControlLayout layout = _controlLayoutNotifier.value'));
      expect(src, contains('_currentVideoControlsTheme(controller, layout)'));
      expect(src, contains('appModel.setVideoControlLayout(layout)'));
      // The phase-1 read-only derivation is gone.
      expect(
          src,
          isNot(contains(
              'VideoControlLayout.fromLegacy(_controlCustomization)')));
    });

    test('customizable render points go through slot-driven item helpers', () {
      expect(src, contains('List<VideoControlItem> _slotChipItems('));
      // Top bar, bottom bar, and screen rails all resolve from slots.
      expect(
          RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topLeft')
              .hasMatch(src),
          isTrue);
      expect(
          RegExp(r'_topBarSlotGroup\(\s*VideoControlSlot\.topRight')
              .hasMatch(src),
          isTrue);
      expect(src, isNot(contains('_topBarSlotButtons(')));
      expect(src, contains('_bottomSlotButtons('));
      expect(src, contains('VideoControlSlot.bottomLeft'));
      expect(src, contains('VideoControlSlot.bottomRight'));
      expect(src, contains('VideoControlSlot.bottomCenter'));
      expect(src, contains('_buildVideoSideRailFor('));
      expect(src, contains('VideoControlSlot.screenLeft'));
      expect(src, contains('VideoControlSlot.screenRight'));
      // Legacy direct placement lookups removed from the render path.
      expect(src, isNot(contains('buttonsFor(VideoControlPlacement.bottom)')));
      expect(
          src, isNot(contains('buttonsFor(VideoControlPlacement.rightRail)')));
    });
  });
}
