// BUG-5208：FushiAppleDarkTier.darkTierOf 重走 buildFushiThemeData 时没传
// shell:、也没合并源主题的扩展——Apple 深色档子树（阅读器 / 播放器 / 视频
// chrome、歌词页）里用户的外壳样式被打回默认（平滑圆角烤进组件形状、侧栏样式 /
// 库页布局 / 色块摆放读到缺省值），源主题上工厂以外的扩展整个丢掉。书内查词
// 弹窗（resolveDictionaryPopupTheme）同样没把外壳样式交给工厂。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_theme.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart'
    show FushiAppleDarkTier;
import 'package:material_ui/material_ui.dart';

/// 工厂以外挂上去的扩展替身。
@immutable
class _ExtraExtension extends ThemeExtension<_ExtraExtension> {
  const _ExtraExtension(this.tag);

  final String tag;

  @override
  _ExtraExtension copyWith({String? tag}) => _ExtraExtension(tag ?? this.tag);

  @override
  _ExtraExtension lerp(covariant ThemeExtension<_ExtraExtension>? other, _) =>
      this;
}

void main() {
  const FushiShellTheme custom = FushiShellTheme(
    railStyle: ShellRailStyle.spine,
    contentLayout: ShellContentLayout.grid,
    blockArrangement: ShellBlockArrangement.scattered,
    smoothCorners: false,
  );

  ThemeData lightTheme({required bool apple}) {
    final ThemeData built = buildFushiThemeData(
      scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E3A8A)),
      textTheme: Typography.material2021().black,
      glass: apple ? FushiGlassMaterial.frosted : FushiGlassMaterial.off,
      glassDesign: apple,
      shell: custom,
    );
    return built.copyWith(
      platform: TargetPlatform.windows,
      extensions: [...built.extensions.values, const _ExtraExtension('x')],
    );
  }

  for (final bool apple in <bool>[false, true]) {
    final String label = apple ? 'Apple' : 'MD3';

    testWidgets('$label：深色档子树读到的是用户的外壳样式与其它扩展', (WidgetTester tester) async {
      late ThemeData inner;
      await tester.pumpWidget(
        MaterialApp(
          theme: lightTheme(apple: apple),
          home: FushiAppleDarkTier(
            child: Builder(
              builder: (BuildContext context) {
                inner = Theme.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      // Apple 下确实换成了深色档（不是原样透传），断言才有意义。
      expect(
        inner.colorScheme.brightness,
        apple ? Brightness.dark : Brightness.light,
      );
      expect(inner.extension<FushiShellTheme>(), custom);
      expect(inner.extension<_ExtraExtension>()?.tag, 'x');
      expect(inner.platform, TargetPlatform.windows);
    });

    test('$label：深色档烤进组件的形状跟随用户的平滑圆角设置', () {
      final ThemeData source = lightTheme(apple: apple);
      final ThemeData dark = FushiAppleDarkTier.darkTierOf(source);
      expect(
        dark.cardTheme.shape.runtimeType,
        source.cardTheme.shape.runtimeType,
      );
      expect(
        dark.dialogTheme.shape.runtimeType,
        source.dialogTheme.shape.runtimeType,
      );
      // 用户关了平滑圆角：不得是工厂缺省（平滑）的 superellipse。
      expect(dark.cardTheme.shape, isNot(isA<RoundedSuperellipseBorder>()));
    });

    test('$label：书内查词弹窗覆盖主题带上用户的外壳样式', () {
      for (final bool lyricsMode in <bool>[false, true]) {
        final DictionaryPopupTheme resolved = resolveDictionaryPopupTheme(
          eink: false,
          einkDark: false,
          readerDark: false,
          buildColorScheme: (Brightness b) => ColorScheme.fromSeed(
            seedColor: const Color(0xFF1E3A8A),
            brightness: b,
          ),
          textTheme: Typography.material2021().black,
          glassDesign: apple,
          glass: apple ? FushiGlassMaterial.frosted : FushiGlassMaterial.off,
          shell: custom,
          lyricsMode: lyricsMode,
        );
        expect(
          resolved.theme.extension<FushiShellTheme>(),
          custom,
          reason: 'lyricsMode=$lyricsMode',
        );
        expect(
          resolved.theme.cardTheme.shape,
          isNot(isA<RoundedSuperellipseBorder>()),
          reason: 'lyricsMode=$lyricsMode',
        );
      }
    });
  }
}
