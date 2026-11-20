/// 复习卡面上常驻的「回到出处」入口（设计稿 11-20 #15 方案 A）：
///
/// - [SrsCardSourceJumpPill]：压在媒体素材（视频片段 / 截图）左下角的胶囊，写明会跳到哪
///   （「回到出处 · 第 3 集 · 12:34」，拿不到定位时写来源名）；
/// - [SrsCardSourceJumpButton]：例句卡右侧的小 ↩，没有媒体素材的卡（小说、网页）也够得着。
///
/// 两者和复习页顶栏的「回到出处」图标调同一个跳转动作（卡面的 `SrsCardFace.onSourceLink`，
/// 复习页里就是顶栏那颗按钮的 `_openSource`），这里只管画和点。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/card_source_origin.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show CardSourceLink;
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:material_ui/material_ui.dart';

/// 胶囊的可见高度；命中区四周再各让 [_kPillHitSlop]，凑够 48dp。
const double _kPillHeight = 32;
const double _kPillHitSlop = 8;

/// 媒体左下角的「回到出处」胶囊。底色与片段上的放大 / 重播角标同一档半透明黑（画面
/// 什么颜色都读得清），MD3 / Apple 共用；图标经 [FushiIcon] 在 Apple 下换成 SF 字形。
class SrsCardSourceJumpPill extends StatelessWidget {
  const SrsCardSourceJumpPill({
    super.key,
    required this.link,
    required this.title,
    required this.database,
    required this.onPressed,
  });

  final CardSourceLink link;

  /// 链接锚文本（书名 / 番名 / 歌名 / 游戏名）：拿不到定位时写它。
  final String title;

  /// 只在视频出处时调用（查播放列表定集数，见 [resolveCardSourceLocatorLabel]）。
  final FushiDatabase Function() database;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = context.fushiType.labelLarge.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w600,
      height: 1.1,
    );
    return Semantics(
      button: true,
      label: t.card_source_open,
      excludeSemantics: true,
      child: FushiHoverLift(
        builder: (BuildContext context, bool hovering) => MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            key: const ValueKey<String>('srs-card-source-jump-pill'),
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.all(_kPillHitSlop),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: Colors.black.withValues(alpha: hovering ? 0.66 : 0.55),
                  shape: const StadiumBorder(),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: _kPillHeight),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 14, 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 6,
                      children: <Widget>[
                        const FushiIcon(
                          FushiIcons.undo,
                          size: 18,
                          color: Colors.white,
                        ),
                        Flexible(
                          child: CardSourceLocatorText(
                            database: database,
                            link: link,
                            style: style,
                            textKey: const ValueKey<String>(
                              'srs-card-source-jump-label',
                            ),
                            format: (String? locator) => cardSourceJumpLabel(
                              locator: locator,
                              title: title,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 例句卡右侧的小 ↩（48dp 命中区；文字进 tooltip 与 Semantics）。
class SrsCardSourceJumpButton extends StatelessWidget {
  const SrsCardSourceJumpButton({
    super.key,
    required this.color,
    required this.onPressed,
  });

  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FushiIconButton(
    key: const ValueKey<String>('srs-card-source-jump-button'),
    icon: FushiIcons.undo,
    tooltip: t.card_source_open,
    size: 20,
    // 20 + 2×14 = 48dp 命中区。
    padding: const EdgeInsets.all(14),
    enabledColor: color,
    onTap: onPressed,
  );
}
