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
      'TODO-174: four persisted immersive modes exist and default to '
      'shortcut-and-lookup', () {
    expect(modeSrc.contains('enum VideoImmersiveMode'), isTrue);
    for (final String name in <String>[
      'full',
      'shortcutAndLookup',
      'lookupOnly',
      'unlockOnly',
    ]) {
      expect(modeSrc.contains("$name('"), isTrue,
          reason: 'missing immersive mode $name');
    }
    // storageValue 保留旧字符串 'seek_and_lookup'（不破坏存量偏好），标识符改为
    // shortcutAndLookup。
    expect(modeSrc.contains("shortcutAndLookup('seek_and_lookup')"), isTrue,
        reason:
            'shortcutAndLookup must keep legacy storage value seek_and_lookup');
    expect(
        modeSrc.contains(
            'static const VideoImmersiveMode fallback = shortcutAndLookup'),
        isTrue,
        reason: 'default immersive mode must be shortcut-and-lookup');
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
      'bool get _immersiveAllowsShortcuts',
      'bool get _immersiveAllowsDoubleTapSeek',
      'bool get _immersiveAllowsLookup',
      'void _runWhenImmersiveAllowsShortcuts(',
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
      pageSrc
          .contains('togglePlayPause: () => _runWhenImmersiveAllowsShortcuts('),
      isTrue,
      reason:
          'keyboard/media actions gate through the shortcuts immersive runner',
    );
    // shortcutAndLookup 放行快捷键但不放行触摸双击 seek：两个 gate 语义必须分离。
    expect(
      pageSrc.contains(
          '_videoImmersiveMode == VideoImmersiveMode.shortcutAndLookup;'),
      isTrue,
      reason: 'shortcuts gate must admit shortcut-and-lookup mode',
    );
  });

  test(
      'TODO-174: shortcut-and-lookup blocks touch double-tap seek, no mode '
      'special-case in pointer-up fallback', () {
    // 触摸双击 seek 门控只放行 full（未锁定亦可），不含 shortcutAndLookup：该模式的
    // 跳转改由快捷键完成，触摸误触被挡。表达式 getter 到 `;` 为止。
    final int dtStart =
        pageSrc.indexOf('bool get _immersiveAllowsDoubleTapSeek =>');
    expect(dtStart, greaterThanOrEqualTo(0),
        reason: 'missing _immersiveAllowsDoubleTapSeek getter');
    final String doubleTapGetter =
        pageSrc.substring(dtStart, pageSrc.indexOf(';', dtStart) + 1);
    expect(doubleTapGetter.contains('VideoImmersiveMode.shortcutAndLookup'),
        isFalse,
        reason:
            'double-tap seek gate must NOT admit shortcut-and-lookup (touch seek off)');
    expect(doubleTapGetter.contains('VideoImmersiveMode.full'), isTrue,
        reason: 'double-tap seek gate still admits full mode');

    final String body = methodBody(
        pageSrc, 'void _handleVideoPointerUp(PointerUpEvent event) {');
    final int gateIdx = body.indexOf(
        'if (_immersiveLocked.value && !_immersiveAllowsDoubleTapSeek) {');
    final int seekIdx = body.indexOf('final bool doubleTapHandled =');
    expect(gateIdx, greaterThanOrEqualTo(0),
        reason: 'locked double-tap must be mode-gated before running seek');
    expect(seekIdx, greaterThan(gateIdx),
        reason: 'double-tap seek runs only after the immersive gate');
    final int seekReturnIdx =
        body.indexOf('if (doubleTapHandled) return;', seekIdx);
    expect(seekReturnIdx, greaterThan(seekIdx),
        reason: 'handled left/right seek must return before platform fallback');
    // 特例块已删除：pointer-up 不再按具体沉浸模式分叉（走到 fallback 必为 full）。
    expect(body.contains('VideoImmersiveMode.'), isFalse,
        reason:
            'pointer-up fallback must not special-case any immersive mode enum');
    final int platformBranch = body.indexOf('if (_isDesktopVideoControls) {');
    expect(platformBranch, greaterThan(seekReturnIdx),
        reason: 'platform pause/fullscreen fallback follows the seek attempt');
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
