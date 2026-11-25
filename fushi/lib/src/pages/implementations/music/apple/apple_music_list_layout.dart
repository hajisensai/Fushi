/// 音乐曲库「歌单」「在线 › 来源」「在线 › 插件」的 Cupertino 版公共件（Apple Music
/// 资料库式分组列表，iOS 27 / macOS 27）：
///
/// - 页边距 [appleMusicListPagePadding]：左右页边、顶部不留（页头底下那档间距由
///   大字页头统一给）、底部让出安全区；
/// - 分组段头 [AppleMusicListSectionHeader]：标题字重段名 + 右侧裸字形 / 文字动作，
///   段头自带上方的分组间距；
/// - 行：图标 / 插件行 [AppleMusicListRow]（行首与封面同尺寸的 fill 方块 + 文字列 +
///   行尾开关 / ›）、动作行 [AppleMusicListActionRow]（「新建歌单…」「添加来源…」
///   「安装插件…」：强调色字形 + 强调色标题）、从属子行 [AppleMusicListSubRow]；
///   三者都基于 [AppleMusicListRowFrame]（分隔线贴行底、左端对齐文字）；
/// - 单行说明 [AppleMusicListNote]（空段 / 组脚 / 未登录）。
///
/// 只在 `isGlassDesign` 为真时用；M3E 不经过这里。尺寸取 [FushiAppleMetrics]
/// （macOS 档乘 `fushiAppleMacScale`），颜色只取 [appleColorsOf] 的系统色令牌。
/// 业务动作由调用方传进来，这里只管画法。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/music/apple/apple_music_browse_widgets.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_recommend_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics, fushiHairline;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show withBottomSafeInset;

/// Apple 分组列表页的内边距：左右页边；顶部 0——曲库各分区排在大字页头下面，页头
/// 已给了「让位 + 一档间距」（`music_library_page.dart` 的 `_buildMastheadPage`），
/// 这里再加就叠两份；段与段的间距由 [AppleMusicListSectionHeader] 自带。
EdgeInsets appleMusicListPagePadding(BuildContext context) {
  final FushiDesignTokens tokens = FushiDesignTokens.of(context);
  return withBottomSafeInset(
    context,
    EdgeInsets.fromLTRB(
      tokens.spacing.page,
      0,
      tokens.spacing.page,
      tokens.spacing.section,
    ),
  );
}

/// 分组段头：段名用 Apple Music 段标题字样（iOS 21 / macOS 18 × 缩放，粗体），右侧
/// [actions] 放裸字形 / 文字按钮（不放色块胶囊）。段头自带上方的分组间距
/// [FushiAppleMetrics.groupSpacing]（分组标题在分组间距里），所以有段头的段与上一段、
/// 与页签行之间都隔这一档；没有段头的段不另留白。
class AppleMusicListSectionHeader extends StatelessWidget {
  const AppleMusicListSectionHeader({
    super.key,
    required this.title,
    this.actions = const <Widget>[],
  });

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final double k = m.scale;
    return Padding(
      padding: EdgeInsets.only(top: m.groupSpacing, bottom: 2 * k),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: appleMusicText(
                  context,
                  size: (m.desktop ? 18 : 21) * k,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ),
          for (final Widget a in actions) ...<Widget>[
            SizedBox(width: 4 * k),
            a,
          ],
        ],
      ),
    );
  }
}

/// 行首方块：与列表行封面同尺寸、同圆角（[appleMusicRowCoverExtent] /
/// [appleMusicRowCoverRadius]）的 fill 底，中间一枚字形；[accent] 时字形强调色
/// （动作行），否则 secondaryLabel（来源 / 插件的类型图标）。
class AppleMusicListIconTile extends StatelessWidget {
  const AppleMusicListIconTile({
    super.key,
    required this.icon,
    this.accent = false,
  });

  final IconData icon;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    return SizedBox.square(
      dimension: appleMusicRowCoverExtent(context),
      child: appleMusicSquircle(
        radius: appleMusicRowCoverRadius(context),
        child: ColoredBox(
          color: c.fill,
          child: Center(
            child: FushiIcon(
              icon,
              size: 22 * k,
              color: accent ? c.accent : c.secondaryLabel,
            ),
          ),
        ),
      ),
    );
  }
}

/// 来源 / 插件一行：行首 [AppleMusicListIconTile] + 标题 + 副行（类型 / 状态 / 版本，
/// 最多两行）+ 行尾 [trailing]（Apple 开关、重排把手或 ›）。[onTap] 是整行的主动作
/// （开关行 = 切换，插件行 = 详情），焦点 + Enter 同一个。
class AppleMusicListRow extends StatelessWidget {
  const AppleMusicListRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle = '',
    this.trailing,
    this.onTap,
    this.separator = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool separator;

  @override
  Widget build(BuildContext context) {
    final double k = FushiAppleMetrics.of(context).scale;
    final Widget? end = trailing;
    return AppleMusicListRowFrame(
      onTap: onTap,
      separator: separator,
      leading: AppleMusicListIconTile(icon: icon),
      trailing: end == null
          ? null
          : Padding(
              padding: EdgeInsetsDirectional.only(start: 8 * k, end: 6 * k),
              child: end,
            ),
      child: AppleMusicRowTexts(
        title: title,
        subtitle: subtitle,
        subtitleMaxLines: 2,
      ),
    );
  }
}

/// 列表里的动作行（「新建歌单…」「添加来源…」「安装插件…」）：与列表行同一副骨架
/// ——行首强调色字形的方块，标题强调色、单行、没有 ›。
class AppleMusicListActionRow extends StatelessWidget {
  const AppleMusicListActionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.separator = true,
  });

  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  final bool separator;

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors c = appleColorsOf(context);
    final double k = FushiAppleMetrics.of(context).scale;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: title,
      excludeSemantics: true,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: AppleMusicListRowFrame(
          onTap: onTap,
          separator: separator,
          leading: AppleMusicListIconTile(icon: icon, accent: true),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: appleMusicText(context, size: 15 * k, color: c.accent),
          ),
        ),
      ),
    );
  }
}

/// 从属子行（Apple Music 的「地区」、插件的账号行）：文字与父行文字左缘对齐，
/// [separator] 在行底画与列表行同一条细线（同一左缩进）。[child] 自己排内容
/// （设置行 / 状态 + 文字按钮）。
class AppleMusicListSubRow extends StatelessWidget {
  const AppleMusicListSubRow({
    super.key,
    required this.child,
    this.separator = true,
  });

  final Widget child;
  final bool separator;

  @override
  Widget build(BuildContext context) {
    final double inset =
        appleMusicRowCoverExtent(context) + appleMusicRowLeadingGap(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsetsDirectional.only(start: inset),
          child: child,
        ),
        if (separator)
          Padding(
            padding: EdgeInsetsDirectional.only(start: inset),
            child: SizedBox(
              height: fushiHairline(context),
              child: ColoredBox(color: appleColorsOf(context).separator),
            ),
          ),
      ],
    );
  }
}

/// 单行说明（空段 / 组脚 / 未登录 / 出错）：secondaryLabel 脚注字，不配插画、
/// 不配大按钮；[trailing] 是行尾的文字按钮（如「去插件管理登录」）。
class AppleMusicListNote extends StatelessWidget {
  const AppleMusicListNote(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final Widget label = Text(text, style: m.footnoteStyle(context));
    final Widget? end = trailing;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8 * m.scale),
      child: end == null
          ? label
          : Row(
              children: <Widget>[
                Expanded(child: label),
                end,
              ],
            ),
    );
  }
}
