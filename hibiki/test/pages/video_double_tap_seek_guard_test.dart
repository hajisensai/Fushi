import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫 (TODO-172/BUG-230 + TODO-173/BUG-231)。
///
/// media_kit 控制条 / 竖滑手势 / 双击分区都跑不了 headless（与
/// `video_orientation_fullscreen_guard_test.dart` 同范式：屏幕方向 / 全屏路由 /
/// hover / tap 手势无法在 widget 测试里真实驱动），故用静态扫描守卫钉住三件事：
///
/// 172: `_mobileControlsTheme` 显式把 `verticalGestureSensitivity` 设成 > media_kit
///      默认 100 的常量（亮度/音量竖滑灵敏度降下来），桌面无此手势不设。
/// 173: `_handleVideoPointerUp` 双击命中后按 `event.position` 的 dx 分区
///      （`_handleDoubleTapSeek`），左/右区 seek/跳句、**中带保留 BUG-221 的暂停/全屏**；
///      `_handleDoubleTapSeek` 读取 [doubleTapSeekSeconds] 配置 + 用 globalToLocal 拿
///      本地 dx + 调既有 seek/跳句原语；设置面板有「双击快进步长」行。
void main() {
  late String pageSrc;
  // TODO-590 batch11：两套 controls 主题已搬到 controls_theme.part.dart，针对主题方法体
  // 的断言改读「合并语料」（主壳 + 全部 part）；仍在主壳的 _handleVideoPointerUp /
  // _handleDoubleTapSeek / 静态常量断言继续读单文件 pageSrc。
  late String pageCorpus;
  late String sheetSrc;

  setUpAll(() {
    pageSrc = File('lib/src/pages/implementations/video_hibiki_page.dart')
        .readAsStringSync();
    pageCorpus = readVideoHibikiSource();
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
    fail('方法体大括号未闭合: $label');
  }

  /// 取一个方法体（含起始签名行到匹配的收尾大括号），大括号配对避免误截嵌套闭包。
  /// [signature] 须以 `{` 结尾（函数体起始花括号即签名最后一个字符）。
  String methodBody(String source, String signature) {
    final int start = source.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '找不到方法签名: $signature');
    final int braceStart = start + signature.length - 1;
    return bodyFromBrace(source, start, braceStart, signature);
  }

  /// 按「方法名前缀 [namePrefix]（如 `bool _foo(`）」定位起点，再向后找参数列表收尾
  /// 后函数体起始的第一个 `{`，避免 dart format 把参数折行后单行签名匹配不到。
  /// 仅用于参数列表本身不含 `{` 的方法（命名参数 `{}` 会误命中）。
  String methodBodyByName(String source, String namePrefix) {
    final int start = source.indexOf(namePrefix);
    expect(start, greaterThanOrEqualTo(0), reason: '找不到方法名前缀: $namePrefix');
    final int braceStart = source.indexOf('{', start);
    expect(braceStart, greaterThanOrEqualTo(0),
        reason: '找不到函数体起始 {: $namePrefix');
    return bodyFromBrace(source, start, braceStart, namePrefix);
  }

  group('TODO-172/BUG-230: 竖滑灵敏度降下来', () {
    test('常量 _videoVerticalGestureSensitivity 存在且 > media_kit 默认 100', () {
      final RegExp re = RegExp(
          r'static const double _videoVerticalGestureSensitivity\s*=\s*([\d.]+)');
      final Match? m = re.firstMatch(pageSrc);
      expect(m, isNotNull, reason: '缺常量 _videoVerticalGestureSensitivity');
      final double value = double.parse(m!.group(1)!);
      expect(value, greaterThan(100.0),
          reason: 'verticalGestureSensitivity 必须 > 默认 100 才更不敏感（值越大越钝）');
    });

    test('_mobileControlsTheme 把该常量传给 MaterialVideoControlsThemeData', () {
      final String body = methodBodyByName(
          pageCorpus, 'MaterialVideoControlsThemeData _mobileControlsTheme(');
      // TODO-590 batch11：搬进 controls_theme.part 后，static const 引用全限定为
      // `_VideoHibikiPageState._videoVerticalGestureSensitivity`（extension 不能裸名解析
      // host class 的 static 成员）；全限定后超 80 列被 dart format 折成两行，故分段断言
      // `verticalGestureSensitivity:` 命名参数 + 其取值是该全限定 static const。
      expect(
        body.contains('verticalGestureSensitivity:') &&
            body.contains(
                '_VideoHibikiPageState._videoVerticalGestureSensitivity,'),
        isTrue,
        reason: '移动控制条主题必须设 verticalGestureSensitivity（TODO-172）',
      );
    });

    test('桌面 _desktopControlsTheme 不设竖滑灵敏度（无此手势，诚实降级）', () {
      final String body = methodBodyByName(pageCorpus,
          'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(');
      expect(body.contains('verticalGestureSensitivity'), isFalse,
          reason: '桌面控制条无竖滑亮度/音量手势，不应设 verticalGestureSensitivity');
    });
  });

  group('TODO-173/BUG-231: 双击左右快进 + 中带保留暂停/全屏', () {
    test('_handleVideoPointerUp 双击命中后先按 dx 分区（早返回），再走平台分流', () {
      final String body = methodBody(
          pageSrc, 'void _handleVideoPointerUp(PointerUpEvent event) {');
      final int seekIdx =
          body.indexOf('_handleDoubleTapSeek(controlsContext, event.position)');
      expect(seekIdx, greaterThanOrEqualTo(0),
          reason: '双击命中后必须先尝试 _handleDoubleTapSeek 左右分区（命中则早返回）');
      final int handledReturnIdx =
          body.indexOf('if (doubleTapHandled) return;', seekIdx);
      expect(handledReturnIdx, greaterThan(seekIdx),
          reason: '_handleDoubleTapSeek 命中左/右区后必须早返回');
      // 分区判定必须排在平台分流（BUG-221 暂停/全屏）之前。
      final int platformBranch = body.indexOf('if (_isDesktopVideoControls) {');
      expect(platformBranch, greaterThan(seekIdx),
          reason: '左右分区早返回必须排在平台暂停/全屏分流之前（中带才落到分流）');
    });

    test('中带仍保留 BUG-221 平台分流（移动 playOrPause / 桌面全屏）—不破坏 149', () {
      final String body = methodBody(
          pageSrc, 'void _handleVideoPointerUp(PointerUpEvent event) {');
      // 与 video_orientation_fullscreen_guard 同样的两条断言：中带逻辑必须原样保留。
      expect(
        body.contains('if (_isDesktopVideoControls) {') &&
            body.contains(
                'unawaited(_controller?.playOrPause() ?? Future<void>.value());'),
        isTrue,
        reason: '中带移动端必须仍 = playOrPause（149 双击暂停不破坏）',
      );
      final int desktopBranch = body.indexOf('if (_isDesktopVideoControls) {');
      final int toggleIdx = body.indexOf(
          '_toggleVideoFullscreen(controlsContext)', desktopBranch);
      final int elseIdx = body.indexOf('} else {', desktopBranch);
      expect(toggleIdx, greaterThan(desktopBranch),
          reason: '中带桌面分支应保留 _toggleVideoFullscreen');
      expect(toggleIdx, lessThan(elseIdx),
          reason: '_toggleVideoFullscreen 必须在桌面分支内（else 是移动端 playOrPause）');
    });

    test('_handleDoubleTapSeek 读配置 + globalToLocal 拿 dx 三等分 + 调既有原语', () {
      final String body =
          methodBodyByName(pageSrc, 'bool _handleDoubleTapSeek(');
      // 读双击行为配置。
      expect(body.contains('_asbConfig.doubleTapSeekSeconds'), isTrue,
          reason: '必须读 doubleTapSeekSeconds 配置驱动分区行为');
      // 0=关：整体跳过分区（向后兼容默认，双击仍走暂停/全屏）。
      expect(body.contains('if (action == 0) return false;'), isTrue,
          reason: '配置 0=关时必须早返回 false（交回平台分流，不分区）');
      // 用本地坐标拿 dx + 宽度做三等分（复用 _isVideoChromePointer 的 globalToLocal 范式）。
      expect(body.contains('globalToLocal(globalPosition).dx'), isTrue,
          reason: '必须用 globalToLocal 把双击点换本地 dx');
      expect(
          body.contains('width / 3') && body.contains('width * 2 / 3'), isTrue,
          reason: '必须按可视区宽度三等分（左/中/右）');
      // 中带落空 → 交回平台分流。
      expect(body.contains('if (!left && !right) return false;'), isTrue,
          reason: '中带（既非左也非右）必须返回 false 交回平台分流');
      // 字幕模式调跳句、秒数模式调相对 seek（复用既有原语，不重造）。
      expect(
        body.contains('_skipCueAndPokeControls(forward: forward)'),
        isTrue,
        reason: '字幕模式必须调既有 _skipCueAndPokeControls 跳句',
      );
      expect(body.contains('_seekRelative(deltaMs)'), isTrue,
          reason: '秒数模式必须调既有 _seekRelative 相对快进/快退');
      // 字幕哨兵走具名常量，不用裸 magic number。
      expect(body.contains('VideoAsbplayerConfig.kDoubleTapSubtitle'), isTrue,
          reason: '字幕哨兵必须用具名常量 kDoubleTapSubtitle');
    });

    test('设置面板有「双击快进步长」行（_buildDoubleTapRow）并接入 playback 详情', () {
      expect(sheetSrc.contains('Widget _buildDoubleTapRow() {'), isTrue,
          reason: '缺双击快进步长设置行 _buildDoubleTapRow');
      expect(sheetSrc.contains('_buildDoubleTapRow(),'), isTrue,
          reason: '_buildDoubleTapRow 必须接入 _buildPlaybackDetail 行列表');
      final String body = methodBody(sheetSrc, 'Widget _buildDoubleTapRow() {');
      expect(body.contains('doubleTapSeekSeconds:'), isTrue,
          reason: 'onChanged 必须 copyWith(doubleTapSeekSeconds:) 落盘');
      expect(body.contains('_commitAsb('), isTrue,
          reason: '必须经 _commitAsb 即时回调 + 落盘');
      expect(body.contains('VideoAsbplayerConfig.kDoubleTapSubtitle'), isTrue,
          reason: '字幕选项必须用具名哨兵常量');
    });
  });
}
