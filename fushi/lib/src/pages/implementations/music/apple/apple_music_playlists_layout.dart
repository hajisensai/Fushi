/// 音乐曲库「歌单」页签的 Cupertino 版公共件（Apple Music 资料库 › 歌单，
/// iOS 27 / macOS 27）：分组列表的段头（标题字重段名 + 右侧裸字形动作）与
/// 列表里的动作行（「新建歌单…」「导入歌单文件…」：与歌单行同高同几何，行首是
/// 与封面同尺寸的 fill 方块 + 强调色字形，标题强调色）。
///
/// 只在 `isGlassDesign` 为真时用；M3E 歌单页不经过这里。尺寸取
/// [FushiAppleMetrics]（macOS 档乘 `fushiAppleMacScale`），颜色只取
/// [appleColorsOf] 的系统色令牌。业务动作（建歌单 / 导入 / 刷新）由调用方传进来，
/// 这里只管画法。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/music/apple/apple_music_browse_widgets.dart';
import 'package:fushi/src/pages/implementations/music/apple/apple_music_recommend_widgets.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 歌单页分组段头：段名用 Apple Music 段标题字样（iOS 21 / macOS 18 × 缩放，
/// 粗体），右侧 [actions] 放裸字形 / 文字按钮（不放色块胶囊）。段头自带上方的
/// 分组间距 [FushiAppleMetrics.groupSpacing]（分组标题在分组间距里），所以
/// 有段头的段与上一段、与页签行之间都隔这一档；没有段头的段不另留白。
class AppleMusicPlaylistsSectionHeader extends StatelessWidget {
  const AppleMusicPlaylistsSectionHeader({
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
          ...actions,
        ],
      ),
    );
  }
}

/// 歌单列表里的动作行（「新建歌单…」「导入歌单文件…」）：与歌单行
/// （[AppleMusicEntityRow]）同一副骨架——行首是与封面同尺寸、同圆角的 fill 方块，
/// 里面一枚强调色字形；标题强调色、单行、没有 ›。
class AppleMusicPlaylistActionRow extends StatelessWidget {
  const AppleMusicPlaylistActionRow({
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
    final double extent = appleMusicRowCoverExtent(context);
    return Semantics(
      button: true,
      label: title,
      excludeSemantics: true,
      child: AppleMusicListRowFrame(
        onTap: onTap,
        separator: separator,
        leading: SizedBox.square(
          dimension: extent,
          child: appleMusicSquircle(
            radius: appleMusicRowCoverRadius(context),
            child: ColoredBox(
              color: c.fill,
              child: Center(
                child: FushiIcon(icon, size: 22 * k, color: c.accent),
              ),
            ),
          ),
        ),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: appleMusicText(context, size: 15 * k, color: c.accent),
        ),
      ),
    );
  }
}

/// 歌单页的单行说明（空段 / 未登录 / 出错）：secondaryLabel 的一行字，不配插画、
/// 不配大按钮。
class AppleMusicPlaylistsNote extends StatelessWidget {
  const AppleMusicPlaylistsNote(this.text, {super.key, this.trailing});

  final String text;

  /// 行尾的文字按钮（如「去插件管理登录」）；null 不画。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final Widget label = Text(text, style: m.footnoteStyle(context));
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8 * m.scale),
      child: trailing == null
          ? label
          : Row(
              children: <Widget>[
                Expanded(child: label),
                trailing!,
              ],
            ),
    );
  }
}
