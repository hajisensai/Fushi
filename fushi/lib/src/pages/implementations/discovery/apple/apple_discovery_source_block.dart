/// 来源块 / 单源页头 /「添加来源」块的 Apple（Cupertino）分支（「浏览」页拍板点 6：
/// 去掉按来源 id 取色的大色块与 M3E tag）。块底是 secondarySystemGroupedBackground
/// 实色卡，glyph 中性灰（[AppleDiscoverySourceGlyph]），能力 / 出处降为副行文字。
///
/// 由 `discovery_source_block.dart` 里的同名 M3E 组件在 `isGlassDesign` 为真时
/// 分派过来，调用方不用改。
library;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/pages/implementations/discovery/apple/apple_discovery_widgets.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

TextStyle _nameStyle(BuildContext context) {
  final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
  return metrics
      .titleStyle(context)
      .copyWith(fontWeight: FontWeight.w600, height: 1.2);
}

/// 来源块（Apple）：中性实色卡 + glyph + 名称 + 副行；失败态副行变红并给「重试」；
/// 有封面条时排在卡尾（封面是内容，不是取色）。
class AppleDiscoverySourceCard extends StatelessWidget {
  const AppleDiscoverySourceCard({
    required this.name,
    required this.onTap,
    required this.chips,
    required this.covers,
    required this.failed,
    required this.height,
    this.icon,
    this.onRetry,
    this.focusId,
    super.key,
  });

  final String name;
  final VoidCallback onTap;
  final List<String> chips;
  final List<Widget> covers;
  final bool failed;
  final double? height;
  final ImageProvider? icon;
  final VoidCallback? onRetry;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final List<Widget> strip = covers.take(3).toList(growable: false);
    final VoidCallback? retry = onRetry;
    final Widget body = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: ClipRect(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  AppleDiscoverySourceGlyph(name: name, icon: icon, size: 40),
                  const Spacer(),
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: _nameStyle(context),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    failed
                        ? t.discovery_source_load_failed
                        : appleDiscoveryCaption(chips),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: metrics
                        .footnoteStyle(context)
                        .copyWith(
                          color: failed
                              ? colors.destructive
                              : colors.secondaryLabel,
                        ),
                  ),
                ],
              ),
            ),
          ),
          if (failed && retry != null)
            Align(
              alignment: AlignmentDirectional.bottomEnd,
              child: FushiPressScale(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: retry,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      t.retry,
                      style: metrics
                          .titleStyle(context)
                          .copyWith(color: colors.accent),
                    ),
                  ),
                ),
              ),
            )
          else if (strip.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 8),
              child: Align(
                alignment: AlignmentDirectional.bottomEnd,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: <Widget>[
                    for (final Widget cover in strip)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 40,
                          height: 60,
                          child: ExcludeSemantics(child: cover),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => FushiPressScale(
        child: FushiAppleGroupSurface(
          child: FushiAppleRow(
            onTap: onTap,
            child: Semantics(
              button: true,
              label: name,
              child: height == null
                  ? body
                  : SizedBox(height: height, child: body),
            ),
          ),
        ),
      ),
    );
  }
}

/// 「添加来源」块（Apple）：中性实色卡 + 强调色「＋」。
class AppleDiscoveryAddSourceCard extends StatelessWidget {
  const AppleDiscoveryAddSourceCard({
    required this.onTap,
    required this.hint,
    required this.height,
    super.key,
  });

  final VoidCallback onTap;
  final String hint;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final Widget body = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FushiIcon(FushiIcons.add, size: 30, color: colors.accent),
          const Spacer(),
          Text(
            '${t.discovery_source_add_title}…',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _nameStyle(context).copyWith(color: colors.accent),
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: metrics.footnoteStyle(context),
          ),
        ],
      ),
    );
    return FushiHoverLift(
      builder: (BuildContext context, bool _) => FushiPressScale(
        child: FushiAppleGroupSurface(
          child: FushiAppleRow(
            onTap: onTap,
            child: height == null
                ? body
                : SizedBox(height: height, child: body),
          ),
        ),
      ),
    );
  }
}

/// 单源页头（Apple）：一行中性实色卡——「‹ 全部来源」强调色文字钮 + glyph + 名称 /
/// 副行 + 行尾 [trailing]。
class AppleDiscoverySourceSelectedHeader extends StatelessWidget {
  const AppleDiscoverySourceSelectedHeader({
    required this.name,
    required this.onBack,
    required this.chips,
    this.icon,
    this.trailing,
    super.key,
  });

  final String name;
  final VoidCallback onBack;
  final List<String> chips;
  final ImageProvider? icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final String caption = appleDiscoveryCaption(chips);
    return FushiAppleGroupSurface(
      child: Padding(
        padding: EdgeInsetsDirectional.fromSTEB(4, 8, metrics.rowHorizontal, 8),
        child: Row(
          children: <Widget>[
            FushiPressScale(
              child: FushiAppleRow(
                key: const ValueKey<String>('discovery_source_back_to_all'),
                onTap: onBack,
                stateBackground: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      FushiIcon(
                        CupertinoIcons.chevron_back,
                        size: metrics.chevronSize + 2,
                        color: colors.accent,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        t.discovery_all_sources,
                        style: metrics
                            .titleStyle(context)
                            .copyWith(color: colors.accent),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            AppleDiscoverySourceGlyph(name: name, icon: icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _nameStyle(context),
                  ),
                  if (caption.isNotEmpty)
                    Text(
                      caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: metrics.footnoteStyle(context),
                    ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
