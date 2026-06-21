import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

void main() {
  test('desktop and mobile controls use shared normal/fullscreen sizing', () {
    // TODO-590 batch11：两套 controls 主题已搬到 video_hibiki/controls_theme.part.dart，
    // 读「合并语料」（主壳 + 全部 part）才能命中它们 + 全文计数仍覆盖主题体内的引用。
    final String source = readVideoHibikiSource();

    // 两套 media_kit controls 主题方法体区间（桌面 + 移动），用于把「主题构造器参数」类
    // 计数限定在主题里——BUG-238 让 _subtitleControlsBottomReserve 也用了同名命名参数
    // `buttonBarHeight:`，全文件裸计数会被它污染（2→3），故 theme 参数按区间内计数。
    final int themesStart = source.indexOf(
        'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(');
    // 搬出后主题是 controls_theme.part 的末两方法，原终点 _buildVideoControlButton 在主壳、
    // 排到了它们之前（合并语料里 part 整体追加在主壳后），故改用 part 顶格 extension 闭合
    // `\n}` 作终点——它紧随末方法 _mobileControlsTheme，恰涵盖桌面 + 移动两套主题。
    final int themesEnd = source.indexOf('\n}', themesStart);
    expect(themesStart, greaterThanOrEqualTo(0));
    expect(themesEnd, greaterThan(themesStart));
    final String themes = source.substring(themesStart, themesEnd);

    // 尺寸基线常量(界面缩放×1.0 时的值)保持 56/32/36(TODO-067 未改基线数值)。
    expect(
        source, contains('static const double _videoButtonBarHeightBase = 56'));
    expect(
        source, contains('static const double _videoControlIconSizeBase = 32'));
    expect(source,
        contains('static const double _videoPlayPauseIconSizeBase = 36'));
    expect(source,
        contains('static const double _videoControlTitleFontSizeBase = 16'));
    expect(source, contains('TextStyle _videoControlTitleStyle(ColorScheme'));

    // TODO-067:控制条尺寸 getter 必须乘以 _videoUiScale,让顶/底栏图标、按钮条高度、
    // 播放键、标题字号都随「界面大小」缩放(视频页被 HibikiAppUiScaleNeutralizer 中和,
    // 否则控制条不吃缩放)。撤掉任一 * _videoUiScale 即转红。
    expect(
      source,
      contains(
          'double get _videoButtonBarHeight => _videoButtonBarHeightBase * _videoUiScale'),
      reason: 'button bar height must follow appUiScale (TODO-067)',
    );
    expect(
      source,
      contains(
          'double get _videoControlIconSize => _videoControlIconSizeBase * _videoUiScale'),
      reason: 'control icon size must follow appUiScale (TODO-067)',
    );
    expect(
      source,
      contains('_videoPlayPauseIconSizeBase * _videoUiScale'),
      reason: 'play/pause icon size must follow appUiScale (TODO-067)',
    );
    expect(
      source,
      contains('_videoControlTitleFontSizeBase * _videoUiScale'),
      reason: 'top-bar title font size must follow appUiScale (TODO-067)',
    );

    // TODO-128:底栏进度/总时长文字（media_kit PositionIndicator）默认硬编码 fontSize
    // 12.0、不传 style 时永不随 appUiScale 缩放（067 漏）。桌面 + 移动两处都必须显式
    // 传 style 把字号乘 _videoUiScale。撤掉任一 * _videoUiScale 即转红。
    expect(
      'fontSize: 12.0 * _videoUiScale'.allMatches(source).length,
      2,
      reason:
          'desktop+mobile position indicators must scale time text by appUiScale (TODO-128)',
    );
    expect(
      source,
      isNot(contains('const MaterialDesktopPositionIndicator()')),
      reason:
          'desktop position indicator must pass a scaled style, not fall back to hardcoded 12.0 (TODO-128)',
    );
    expect(
      source,
      isNot(contains('const MaterialPositionIndicator()')),
      reason:
          'mobile position indicator must pass a scaled style, not fall back to hardcoded 12.0 (TODO-128)',
    );

    expect(
      'buttonBarButtonSize: _videoControlIconSize'.allMatches(themes).length,
      2,
      reason:
          'media_kit built-in fullscreen buttons must use the same shared icon size as custom controls',
    );
    expect(
      'buttonBarHeight: _videoButtonBarHeight'.allMatches(themes).length,
      2,
      reason:
          'normal and fullscreen controls should share one explicit touch-height source',
    );
    expect(
      '_videoControlIconSize'.allMatches(source).length,
      greaterThanOrEqualTo(10),
      reason: 'all top/bottom control buttons should share one icon size',
    );
    expect(
      'iconSize: _videoPlayPauseIconSize'.allMatches(source).length,
      2,
      reason: 'desktop and mobile play buttons should use the same size',
    );
    expect(source, isNot(contains('iconSize: 32')));
    expect(source, isNot(contains('iconSize: 36')));
    expect(
      source,
      isNot(contains(
          'style: const TextStyle(color: Colors.white, fontSize: 16)')),
    );

    // TODO-067:左下快进快退用左右镜像对称、平行的 fast_rewind/forward(实心双三角),
    // 取代视觉重心偏移的 replay_10/forward_10(带数字「10」圆弧箭头,显歪)。
    expect(source, isNot(contains('Icons.replay_10')),
        reason:
            'lopsided replay_10 replaced by parallel fast_rewind (TODO-067)');
    expect(source, isNot(contains('Icons.forward_10')),
        reason:
            'lopsided forward_10 replaced by parallel fast_forward (TODO-067)');
    // BUG-257：桌面 + 移动底栏合并为单一 _centeredBottomControlBar(desktop:)，故并行
    // fast_rewind/forward 各只出现一次（不再 per-theme 重复）。守卫意图（用对称图标、
    // 不用显歪的 replay_10/forward_10）仍由上面的 isNot(replay_10/forward_10) + 此处存在性守住。
    expect(
      'Icons.fast_rewind_rounded'.allMatches(source).length,
      1,
      reason:
          'shared bottom bar uses parallel fast_rewind once (BUG-257/TODO-067)',
    );
    expect(
      'Icons.fast_forward_rounded'.allMatches(source).length,
      1,
      reason:
          'shared bottom bar uses parallel fast_forward once (BUG-257/TODO-067)',
    );
  });

  test('fullscreen video route is neutralized like the windowed video page',
      () {
    // _pushNeutralizedVideoFullscreen / _buildFullscreenButton 仍在主壳（合并语料前段），
    // 此切片相对顺序不变；统一读合并语料即可。
    final String source = readVideoHibikiSource();

    expect(source, contains('Future<void> _pushNeutralizedVideoFullscreen('),
        reason:
            'media_kit default fullscreen route is outside VideoHibikiPage.neutralized; Hibiki must push its own neutralized route');
    final int helper = source.indexOf(
      'Future<void> _pushNeutralizedVideoFullscreen(',
    );
    expect(helper, greaterThanOrEqualTo(0));
    final int end = source.indexOf('Widget _buildFullscreenButton(', helper);
    expect(end, greaterThan(helper));
    final String helperBody = source.substring(helper, end);

    expect(helperBody, contains('HibikiAppUiScaleNeutralizer('),
        reason: 'fullscreen route must cancel the app-wide UI scale too');
    expect(helperBody, contains('VideoStateInheritedWidget('),
        reason: 'fullscreen route must preserve media_kit video state');
    expect(helperBody, contains('FullscreenInheritedWidget('),
        reason:
            'fullscreen controls must still see media_kit fullscreen context');
    expect(helperBody, contains('width: null'));
    expect(helperBody, contains('height: null'));
    expect(source, contains('toggleFullscreenOnDoublePress: false'),
        reason:
            'package default double-click route is unneutralized; Hibiki should replace it with its own double-click handler');
    expect(source, contains('void _handleVideoPointerUp('),
        reason: 'double-click fullscreen must remain available');
    expect(source, isNot(contains('const MaterialDesktopFullscreenButton()')));
    expect(source, isNot(contains('const MaterialFullscreenButton()')));
    expect(
      source,
      isNot(contains('package:media_kit_video/media_kit_video_controls/src/')),
      reason:
          'fullscreen route must use media_kit public exports, not private package internals',
    );
  });
}
