import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/media_cover_standalone_source.dart';
import 'package:fushi/src/media/nsfw/media_nsfw_cover.dart';
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isEinkTheme;
import 'package:fushi/src/utils/components/fushi_continue_card_row.dart'
    show coverColorSchemeCache;
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors;
import 'package:fushi/src/utils/components/fushi_generated_cover.dart'
    show fushiGeneratedCoverHue;
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 游戏首页的游戏封面（两套版面共用）：来源解析与首页 Activity / 游戏库共用；没有
/// 封面或解码失败时画 [GalgameCoverPlaceholder]（饱和色块 + 首字），不再是一块灰。
///
/// 本页所有游戏封面（继续卡、最近玩过、动态行缩略图）都经过这里：NSFW（成人向标记
/// 或所在 NSFW 合集，拍板台 w04vrhUAaX）在这一处统一打模糊。小缩略图不压「已隐藏」
/// 图标。只画封面内容层，外框 / 圆角 / 投影由版面各自的封面框负责。
class GalgameCoverArt extends StatelessWidget {
  const GalgameCoverArt({
    required this.game,
    this.decodeWidth = kLocalCoverDecodePixelWidth,
    super.key,
  });

  final GalgameEntry game;

  /// 解码宽度：大卡用默认档，缩略图 / 小封面传 [kActivityCoverDecodePixelWidth]。
  final int decodeWidth;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? provider = galgameHomeCoverImage(
      game,
      decodeWidth: decodeWidth,
    );
    if (provider == null) return GalgameCoverPlaceholder(game: game);
    return MediaNsfwCover(
      target: MediaNsfwTarget.game(game.id, adult: game.isNsfw),
      showIcon: decodeWidth > kActivityCoverDecodePixelWidth,
      child: Image(
        image: provider,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
            GalgameCoverPlaceholder(game: game),
      ),
    );
  }
}

/// 无封面占位：按游戏 id 稳定地落在 primary / secondary / tertiary 三种饱和
/// container 色块之一（同一游戏每次同色、相邻游戏多半不同色），中间是游戏名首字；
/// 够大时右下角再压一枚淡手柄图标。Apple 落到强调色淡染（[fushiCardToneColors]），
/// 墨水屏无底色、只留字。
class GalgameCoverPlaceholder extends StatelessWidget {
  const GalgameCoverPlaceholder({required this.game, super.key});

  final GalgameEntry game;

  static const List<FushiCardTone> _tones = <FushiCardTone>[
    FushiCardTone.primary,
    FushiCardTone.secondary,
    FushiCardTone.tertiary,
  ];

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    int seed = 0;
    for (final int unit in game.id.codeUnits) {
      seed = (seed * 31 + unit) & 0x3fffffff;
    }
    final FushiCardColors? colors = fushiCardToneColors(
      context,
      _tones[seed % _tones.length],
    );
    final Color background = colors?.container ?? cs.surface;
    final Color foreground = colors?.onContainer ?? cs.onSurface;
    final String name = game.displayName.trim();
    final String initial = name.isEmpty
        ? ''
        : name.characters.first.toUpperCase();
    return ColoredBox(
      color: background,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool showBadge =
              initial.isNotEmpty &&
              constraints.maxWidth.isFinite &&
              constraints.maxWidth >= 72;
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Center(
                child: FractionallySizedBox(
                  widthFactor: 0.56,
                  heightFactor: 0.42,
                  child: FittedBox(
                    child: initial.isEmpty
                        ? FushiIcon(FushiIcons.games, color: foreground)
                        : Text(
                            initial,
                            style: context.fushiType.displayMediumEmphasized
                                .copyWith(color: foreground),
                          ),
                  ),
                ),
              ),
              if (showBadge)
                PositionedDirectional(
                  end: 8,
                  bottom: 8,
                  child: FushiIcon(
                    FushiIcons.games,
                    size: 16,
                    color: foreground.withValues(alpha: 0.6),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 游戏封面图源（与游戏库同一条来源链：游戏只有本机路径）；没有封面为 null。
ImageProvider? galgameHomeCoverImage(
  GalgameEntry game, {
  int decodeWidth = kLocalCoverDecodePixelWidth,
}) => resolveStandaloneCoverImage(
  localPath: game.coverPath,
  decodeWidth: decodeWidth,
);

/// 块配色：封面取色（[coverColorSchemeCache]，与库页色块同一份缓存）派生
/// [FushiCoverBlockColors]；没封面按标题哈希色相（与生成封面同色）；墨水屏中性色。
class GalgameBlockPalette extends StatefulWidget {
  const GalgameBlockPalette({
    required this.title,
    required this.image,
    required this.builder,
    super.key,
  });

  final String title;
  final ImageProvider? image;
  final Widget Function(BuildContext context, FushiCoverBlockColors colors)
  builder;

  @override
  State<GalgameBlockPalette> createState() => _GalgameBlockPaletteState();
}

class _GalgameBlockPaletteState extends State<GalgameBlockPalette> {
  ColorScheme? _scheme;
  ImageProvider? _for;
  Brightness? _brightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(GalgameBlockPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    _resolve();
  }

  void _resolve() {
    final ImageProvider? image = isEinkTheme(context) ? null : widget.image;
    final Brightness brightness = Theme.of(context).brightness;
    if (image == _for && brightness == _brightness) return;
    _for = image;
    _brightness = brightness;
    if (image == null) {
      _scheme = null;
      return;
    }
    _scheme = coverColorSchemeCache.peek(image, brightness);
    if (_scheme != null) return;
    coverColorSchemeCache.resolve(image, brightness).then((ColorScheme? s) {
      if (!mounted || _for != image || _brightness != brightness) return;
      setState(() => _scheme = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiCoverBlockColors colors =
        _scheme == null && widget.image == null && !isEinkTheme(context)
        ? FushiCoverBlockColors.fromHue(
            theme,
            fushiGeneratedCoverHue(widget.title),
          )
        : FushiCoverBlockColors.resolve(theme, _scheme);
    return widget.builder(context, colors);
  }
}
