import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

void main() {
  late String modeSrc;
  late String prefsSrc;
  late String appModelSrc;
  late String pageSrc;
  late String sheetSrc;

  setUpAll(() {
    String readOrEmpty(String path) {
      final File file = File(path);
      return file.existsSync() ? file.readAsStringSync() : '';
    }

    modeSrc = readOrEmpty('lib/src/media/video/video_immersive_mode.dart');
    prefsSrc = readOrEmpty('lib/src/models/preferences_repository.dart');
    appModelSrc = File('lib/src/models/app_model.dart').readAsStringSync();
    // TODO-590 batch16: `onCharTap: _handleSubtitleLookupTap,` 在 _buildVideoControlsInner
    // 已搬到 video_hibiki/layout.part.dart，故读「主壳 + 全部 part」合并语料；本测试其余
    // pageSrc 断言（_videoImmersiveMode 等 getter、_handleVideoPointerUp / _handleSecondaryTap
    // 方法体）都还在主壳、在合并语料里照旧连续，methodBody 大括号匹配不受影响。
    pageSrc = readVideoHibikiSource();
    sheetSrc = File('lib/src/media/video/video_quick_settings_sheet.dart')
        .readAsStringSync();
  });

  String bodyFromBrace(String source, int start, int braceStart, String label) {
    int depth = 0;
    for (int i = braceStart; i < source.length; i++) {
      final String ch = source[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return source.substring(start, i + 1);
      }
    }
    fail('method body brace never closed: $label');
  }

  String methodBody(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $signature');
    final int braceStart = start + signature.length - 1;
    return bodyFromBrace(source, start, braceStart, signature);
  }

  test(
      'TODO-174: four persisted immersive modes exist and default to lookup-only',
      () {
    expect(modeSrc.contains('enum VideoImmersiveMode'), isTrue);
    for (final String name in <String>[
      'full',
      'seekAndLookup',
      'lookupOnly',
      'unlockOnly',
    ]) {
      expect(modeSrc.contains("$name('"), isTrue,
          reason: 'missing immersive mode $name');
    }
    expect(
        modeSrc
            .contains('static const VideoImmersiveMode fallback = lookupOnly'),
        isTrue,
        reason: 'default immersive mode must be lookup-only');
    expect(prefsSrc.contains("'video_immersive_mode'"), isTrue,
        reason: 'immersive mode must persist in preferences');
    expect(appModelSrc.contains('VideoImmersiveMode get videoImmersiveMode'),
        isTrue,
        reason: 'AppModel must expose the video immersive mode preference');
  });

  test(
      'TODO-174: player gates controls, double-tap, lookup, and shortcuts by mode',
      () {
    for (final String helper in <String>[
      'VideoImmersiveMode get _videoImmersiveMode',
      'bool get _immersiveAllowsFullControls',
      'bool get _immersiveAllowsDoubleTapSeek',
      'bool get _immersiveAllowsLookup',
      'void _runWhenImmersiveAllowsFullControls(',
    ]) {
      expect(pageSrc.contains(helper), isTrue, reason: 'missing $helper');
    }
    expect(
      pageSrc.contains('onCharTap: _handleSubtitleLookupTap,'),
      isTrue,
      reason: 'subtitle lookup must route through the runtime immersive gate',
    );
    expect(
      pageSrc.contains('if (!_immersiveAllowsLookup) return;'),
      isTrue,
      reason: 'subtitle lookup must be disabled only by unlock-only mode',
    );
    expect(
      pageSrc.contains(
          'if (_immersiveLocked.value && !_immersiveAllowsDoubleTapSeek) {'),
      isTrue,
      reason: 'double-tap seek must be mode-gated while immersive locked',
    );
    expect(
      pageSrc.contains(
          'togglePlayPause: () => _runWhenImmersiveAllowsFullControls('),
      isTrue,
      reason:
          'keyboard/media actions must be blocked outside full mode while locked',
    );
  });

  test(
      'TODO-174: seek-and-lookup locked mode consumes unsafe double-tap fallback',
      () {
    final String body = methodBody(
        pageSrc, 'void _handleVideoPointerUp(PointerUpEvent event) {');
    final int seekIdx = body.indexOf('final bool doubleTapHandled =');
    final int seekCallIdx =
        body.indexOf('_handleDoubleTapSeek(controlsContext, event.position)');
    expect(seekIdx, greaterThanOrEqualTo(0),
        reason:
            'double-tap seek result must be captured before platform fallback');
    expect(seekCallIdx, greaterThan(seekIdx),
        reason:
            'captured double-tap result must come from _handleDoubleTapSeek');
    final int seekReturnIdx =
        body.indexOf('if (doubleTapHandled) return;', seekIdx);
    expect(seekReturnIdx, greaterThan(seekIdx),
        reason: 'handled left/right seek must return before fallback');
    final int seekAndLookupBlockIdx =
        body.indexOf('if (_immersiveLocked.value &&', seekReturnIdx);
    final int seekAndLookupModeIdx = body.indexOf(
        '_videoImmersiveMode == VideoImmersiveMode.seekAndLookup',
        seekAndLookupBlockIdx);
    expect(seekAndLookupBlockIdx, greaterThan(seekReturnIdx),
        reason:
            'locked seek-and-lookup must consume center/off double-taps before pause/fullscreen fallback');
    expect(seekAndLookupModeIdx, greaterThan(seekAndLookupBlockIdx),
        reason: 'fallback-consuming gate must target seek-and-lookup mode');
    final int platformBranch = body.indexOf('if (_isDesktopVideoControls) {');
    expect(platformBranch, greaterThan(seekAndLookupBlockIdx),
        reason:
            'pause/fullscreen fallback must be unreachable in locked seek-and-lookup mode');
  });

  test('TODO-174: locked context menu is available only to full-control mode',
      () {
    final String body = methodBody(
        pageSrc, 'void _handleSecondaryTap(Offset globalPosition) {');
    final int fullControlsGate =
        body.indexOf('if (!_immersiveAllowsFullControls) return;');
    expect(fullControlsGate, greaterThanOrEqualTo(0),
        reason:
            'right-click menu exposes full controls and must be gated by immersive mode');
    final int menuIdx = body.indexOf('showMenu<VoidCallback>(');
    expect(menuIdx, greaterThan(fullControlsGate),
        reason:
            'full-control gate must run before building/showing the context menu');
  });

  test('TODO-174: video settings sheet exposes the four-mode selector', () {
    expect(sheetSrc.contains('initialImmersiveMode'), isTrue);
    expect(sheetSrc.contains('onImmersiveModeChanged'), isTrue);
    expect(sheetSrc.contains('Widget _buildImmersiveModeRow()'), isTrue);
    expect(sheetSrc.contains('VideoImmersiveMode.values'), isTrue);
    expect(sheetSrc.contains('_buildImmersiveModeRow(),'), isTrue,
        reason:
            'immersive selector must live in the playback video settings group');
  });

  test(
      'TODO-209: immersive selector is a dropdown picker, not a 4-segment strip '
      '(long labels must never be clipped on a narrow panel)', () {
    // 找到 _buildImmersiveModeRow 方法体（到下一个方法定义为止），只在它内部断言，
    // 不被同文件别处的 segmented 行（如档位选择器）干扰。
    final String body =
        methodBody(sheetSrc, 'Widget _buildImmersiveModeRow() {');
    // 根因修复 TODO-209：4 个较长中文标签用等宽不换行的 SegmentedButton 会被裁，
    // 必须改用下拉单选 picker（行内只显示当前项、展开为竖排单选列表）。
    expect(
      body.contains('AdaptiveSettingsPickerRow<VideoImmersiveMode>'),
      isTrue,
      reason:
          'immersive mode must use a dropdown picker so long labels are not clipped',
    );
    expect(
      body.contains('AdaptiveSettingsSegmentedRow'),
      isFalse,
      reason:
          'immersive mode must NOT use a fixed-width segmented strip (clips the 4 long labels)',
    );
    // 4 个模式仍由 VideoImmersiveMode.values 全量映射成选项，一个不少。
    expect(body.contains('VideoImmersiveMode.values'), isTrue,
        reason: 'all four immersive modes must be offered as picker options');
    expect(body.contains('AdaptiveSettingsPickerOption<VideoImmersiveMode>'),
        isTrue,
        reason: 'each immersive mode must map to one picker option');
  });
}
