// BUG-3495：开关类按钮（收藏 / 字幕显隐）被用户拖进主控制行（上一句 / 播放 /
// 下一句那一行）时，M3E tonal toggle 的未选态退成 surfaceContainer——正好是
// 遥控卡自己的底色，于是只剩一个裸图标，不和前后句的 tonal 容器成组。
// 修复后同一行的按钮无论开关都铺与前后句同一个 secondaryContainer；次组行与
// Apple 设计系统保持原样。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_remote_control_layout.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_control_card.dart';
import 'package:fushi/src/pages/implementations/video_remote/video_remote_models.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show FushiIconButtonControl;
import 'package:material_ui/material_ui.dart';

ThemeData _theme({required Brightness brightness, bool apple = false}) {
  final ThemeData base = apple
      ? buildFushiThemeData(
          scheme: ColorScheme.fromSeed(
            seedColor: kFushiDefaultSeed,
            brightness: brightness,
          ),
          textTheme: const TextTheme(),
          glassDesign: true,
        )
      : buildFushiFallbackTheme(brightness);
  return base.copyWith(platform: TargetPlatform.android);
}

Widget _app({
  required VideoRemoteControlLayout layout,
  required ThemeData theme,
  bool favorited = false,
  bool subtitlesVisible = true,
}) {
  return MaterialApp(
    theme: theme,
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: SizedBox(
          width: 400,
          child: VideoRemoteControlCard(
            layout: layout,
            nowPlaying: VideoRemoteNowPlaying(
              title: 'Test',
              currentFavorited: favorited,
              subtitlesVisible: subtitlesVisible,
            ),
            onControl: (_) {},
          ),
        ),
      ),
    ),
  );
}

Finder _control(VideoRemoteControlItem item) =>
    find.byKey(ValueKey<String>('video-remote-control-${item.storageValue}'));

/// 按钮实际画出来的容器色（ButtonStyleButton 内层 Material 的 color）。
Color? _fill(WidgetTester tester, VideoRemoteControlItem item) {
  final Material material = tester.widget<Material>(
    find.descendant(of: _control(item), matching: find.byType(Material)).first,
  );
  return material.color;
}

final VideoRemoteControlLayout _favoriteInPrimary = VideoRemoteControlLayout
    .defaults
    .moveItem(VideoRemoteControlItem.favorite, VideoRemoteControlSlot.primary)
    .moveItem(
      VideoRemoteControlItem.subtitleVisibility,
      VideoRemoteControlSlot.primary,
    );

void main() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets('MD3 ${brightness.name}：主控制行的开关键关着也铺与前后句相同的 tonal 容器', (
      WidgetTester tester,
    ) async {
      final ThemeData theme = _theme(brightness: brightness);
      final ColorScheme cs = theme.colorScheme;
      await tester.pumpWidget(
        _app(
          layout: _favoriteInPrimary,
          theme: theme,
          favorited: false,
          subtitlesVisible: false,
        ),
      );
      await tester.pump();

      final Color? previous = _fill(tester, VideoRemoteControlItem.previousCue);
      expect(previous, cs.secondaryContainer);
      // 修复前这两个是 surfaceContainer（= 卡片底色），视觉上没有容器。
      expect(_fill(tester, VideoRemoteControlItem.favorite), previous);
      expect(
        _fill(tester, VideoRemoteControlItem.subtitleVisibility),
        previous,
      );
      expect(
        _fill(tester, VideoRemoteControlItem.favorite),
        isNot(cs.surfaceContainer),
      );

      // 选中语义仍在（无障碍 toggled + M3E 选中形状），只是不再靠底色区分。
      final FushiIconButtonControl favorite = tester.widget(
        _control(VideoRemoteControlItem.favorite),
      );
      expect(favorite.isSelected, isFalse);
    });
  }

  testWidgets('MD3：开着的开关键也是同一个 tonal 容器', (WidgetTester tester) async {
    final ThemeData theme = _theme(brightness: Brightness.light);
    await tester.pumpWidget(
      _app(layout: _favoriteInPrimary, theme: theme, favorited: true),
    );
    await tester.pump();
    final FushiIconButtonControl favorite = tester.widget(
      _control(VideoRemoteControlItem.favorite),
    );
    expect(favorite.isSelected, isTrue);
    expect(
      _fill(tester, VideoRemoteControlItem.favorite),
      _fill(tester, VideoRemoteControlItem.previousCue),
    );
  });

  testWidgets('MD3：不在主控制行的按钮保持原样（无底色图标按钮）', (WidgetTester tester) async {
    final ThemeData theme = _theme(brightness: Brightness.light);
    // 出厂布局：收藏在次组行。
    await tester.pumpWidget(
      _app(layout: VideoRemoteControlLayout.defaults, theme: theme),
    );
    await tester.pump();
    final FushiIconButtonControl favorite = tester.widget(
      _control(VideoRemoteControlItem.favorite),
    );
    expect(favorite.style, isNull);
    final Color? fill = _fill(tester, VideoRemoteControlItem.favorite);
    expect(fill == null || fill.a == 0, isTrue, reason: 'fill=$fill');
  });

  testWidgets('非开关键与 Apple 设计系统不覆盖组件默认样式', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        layout: _favoriteInPrimary,
        theme: _theme(brightness: Brightness.light, apple: true),
      ),
    );
    await tester.pump();
    // Apple：tonal = 中性灰底圆钮，未选与前后句本就同色；传底色会被当成
    // 「自定义底色」画成玻璃强调钮，所以这里必须不传。
    final FushiIconButtonControl favorite = tester.widget(
      _control(VideoRemoteControlItem.favorite),
    );
    expect(favorite.style, isNull);
    final BuildContext context = tester.element(
      _control(VideoRemoteControlItem.favorite),
    );
    expect(videoRemotePrimaryToggleStyle(context, isToggle: true), isNull);
  });

  testWidgets('MD3：非开关键（如倍速）放进主控制行沿用 tonal 默认', (WidgetTester tester) async {
    final ThemeData theme = _theme(brightness: Brightness.light);
    await tester.pumpWidget(
      _app(
        layout: VideoRemoteControlLayout.defaults.moveItem(
          VideoRemoteControlItem.speed,
          VideoRemoteControlSlot.primary,
        ),
        theme: theme,
      ),
    );
    await tester.pump();
    final FushiIconButtonControl speed = tester.widget(
      _control(VideoRemoteControlItem.speed),
    );
    expect(speed.style, isNull);
    expect(
      _fill(tester, VideoRemoteControlItem.speed),
      _fill(tester, VideoRemoteControlItem.previousCue),
    );
  });
}
