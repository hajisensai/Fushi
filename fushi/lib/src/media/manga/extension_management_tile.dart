import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';

import 'package:fushi/src/media/online/installed_online_source_row.dart'
    show onlineSourceLanguageLabel;
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart'
    show FushiCoverBlockColors;
import 'package:fushi/src/utils/components/fushi_generated_cover.dart'
    show fushiGeneratedCoverHue;
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/glass/fushi_expressive_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/fushi_sliver_width_builder.dart';

/// 一行元信息：跳过空片段后用 ` · ` 串成**单行**。
///
/// 扩展行以前是「语言 · 版本」`\n`「完整 URL」两行硬换行，副标题独占两行、
/// 行高冲到 ~89px，手机一屏只剩六条；URL 还带 `https://` 前缀把有效信息
/// 挤出可视区。收成一行后行高回到 ~62px，且与本仓其它列表（下载任务卡
/// `download_task_card.dart`、章节行 `manga_chapter_list.dart`）同一写法。
String mangaSourceMetaLine(Iterable<String?> parts) => parts
    .map((String? part) => part?.trim() ?? '')
    .where((String part) => part.isNotEmpty)
    .join(' · ');

/// 源地址的可读短形：去掉 scheme / `www.` / 末尾斜杠，保留主机（+ 非根路径）。
/// 解析不动的（Aidoku 只有包 id、没有 baseUrl）原样返回。
String mangaSourceHostLabel(String value) {
  final String raw = value.trim();
  if (raw.isEmpty) return '';
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) return raw;
  final String host = uri.host.startsWith('www.')
      ? uri.host.substring(4)
      : uri.host;
  final String path = uri.path == '/' ? '' : uri.path;
  return '$host$path';
}

/// 扩展行动作按钮的强调层级（M3E 按钮族）。
///
/// 同一行里的动作按语义分级而不是一律文字按钮：安装 = filled（主操作）、
/// 有更新 = tonal（强调但不抢主色）、卸载 = outlined（破坏性的次要动作）、
/// 预览 = text（辅助）。
enum ExtensionTileActionStyle { filled, tonal, outlined, text }

/// Shared visual contract for Mihon APK and Aidoku AIX extension rows.
/// Runtime-specific pages supply metadata and actions; spacing, icon fallback,
/// warning badge, progress, enable switch and buttons stay identical.
///
/// 拼贴改版形态（2026-11-16）：每个扩展一张独立圆角卡片（[FushiCard]，悬停轻抬
/// [FushiHoverLift]），扩展目录在宽屏排成多列（[ExtensionCatalogSliver]）。卡内
/// 一行头部 = 按名字取色的图标色块 + 名称（后跟 NSFW / 「可更新」小胶囊）+ 一行
/// 精简元信息（`JA · 1.4.2 · lib 1.4 · ↓ 1.2k 次下载`，纯文字点分，不再是一排灰
/// 胶囊）+ 行尾开关与动作；可展开详情（[details]，Mihon 的「包含的源」）在头部
/// 下方；安装中在卡片底部展开一条波浪进度。有更新的卡片描一圈主色边——在一屏卡片
/// 里一眼认出哪几张要动。
/// 旧的整块 [subtitle] 仍可用（Aidoku 路径），与结构化参数可以并存。
class MangaExtensionManagementTile extends StatelessWidget {
  const MangaExtensionManagementTile({
    required this.title,
    this.subtitle,
    super.key,
    this.iconUrl,
    this.contentWarning = false,
    this.busy = false,
    this.enabled,
    this.onEnabledChanged,
    this.secondaryLabel,
    this.onSecondary,
    this.secondaryStyle = ExtensionTileActionStyle.text,
    this.primaryLabel,
    this.onPrimary,
    this.primaryStyle = ExtensionTileActionStyle.text,
    this.subtitleMaxLines = 1,
    this.groupIndex,
    this.groupCount,
    this.metaChips = const <String>[],
    this.downloadsLabel,
    this.updateAvailable = false,
    this.details,
  });

  final String title;

  /// 旧式整块副标题（一行元信息文本）。结构化调用点用 [metaChips] /
  /// [downloadsLabel] / [details]，两者可以并存（先元信息、后它、再详情）。
  final Widget? subtitle;
  final String? iconUrl;
  final bool contentWarning;
  final bool busy;
  final bool? enabled;
  final ValueChanged<bool>? onEnabledChanged;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final ExtensionTileActionStyle secondaryStyle;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final ExtensionTileActionStyle primaryStyle;

  /// 副标题行数上限。默认 1（一行元信息）；Mihon 的「可用扩展」行在副标题里
  /// 展开自带源清单，由调用点显式放宽。
  final int subtitleMaxLines;

  /// 本行在所属分组（同一仓库 / 同一列表段）里的位置与总行数。两者都给时
  /// 整段读作一个分组（MD3 分段 / Apple inset grouped，见
  /// [FushiGroupedListItem]）；缺省时是一张张独立卡片（扩展目录的默认形态）。
  final int? groupIndex;
  final int? groupCount;

  /// 元信息片段（语言 / 版本 / lib / 站点），点分成一行文字。
  final List<String> metaChips;

  /// 下载量文案（`1.2k 次下载` / `无下载数据`），排在元信息之后、带下载图标。
  final String? downloadsLabel;

  /// 仓库里有比已装版本更新的版本：标题后挂一枚「可更新」强调小胶囊，卡片描
  /// 主色边。
  final bool updateAvailable;

  /// 副标题下方的可展开详情（Mihon 的「包含的源」）。
  final Widget? details;

  /// 窄于此宽度时文字动作按钮下移到副标题下方一行。
  ///
  /// 2026-10 体验优化：trailing 的 `Wrap` 在 `FushiListItem` 的 `Row` 里拿到
  /// 的是无界宽度，永远不会换行——窄屏上「预览 + 安装」两个按钮加开关直接
  /// 把标题列挤到只剩几个字甚至溢出。
  static const double compactActionsBreakpoint = 480;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) => _buildTile(
        context,
        narrow: constraints.maxWidth < compactActionsBreakpoint,
      ),
    );
  }

  Widget _buildTile(BuildContext context, {required bool narrow}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Widget row = _buildBody(context, tokens, narrow: narrow);
    final int? index = groupIndex;
    final int? count = groupCount;
    if (index != null && count != null) {
      return FushiGroupedListItem(
        index: index,
        count: count,
        // 组尾与下一组之间留一段组间距（组内是 MD3 2px 缝 / Apple 无缝）。
        margin: EdgeInsets.only(
          bottom: index >= count - 1 ? tokens.spacing.gap : 0,
        ),
        // Apple 分隔线从标题起点开始：行内边距 + 图标 + 图标与文字间距。
        separatorIndent:
            tokens.spacing.rowHorizontal -
            4 +
            _ExtensionIcon._size +
            FushiAppleMetrics.of(context).leadingGap,
        child: row,
      );
    }
    final ColorScheme colors = Theme.of(context).colorScheme;
    // 卡片本身不可点（动作都在按钮上），悬停只做轻抬，不做整卡放大的「可点」暗示。
    return FushiHoverLift(
      scale: 1.01,
      builder: (BuildContext context, bool _) => FushiCard(
        // 卡与卡之间必须有实边距：圆角卡片外边距为 0 时，相邻卡片之间只从圆角
        // 缺口漏出几处页面底色，看着像锯齿而不是分隔。
        margin: EdgeInsets.only(bottom: tokens.spacing.gap),
        padding: EdgeInsets.zero,
        pressScale: false,
        borderColor: updateAvailable && !isEinkTheme(context)
            ? colors.primary.withValues(alpha: 0.55)
            : null,
        child: row,
      ),
    );
  }

  /// 行本体 + 底部的安装进度槽（busy 时弹簧展开一条波浪进度，结束后收起）。
  Widget _buildBody(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool narrow,
  }) {
    final FushiMotionScheme motion = context.fushiMotion;
    final double horizontal = tokens.spacing.rowHorizontal - 4;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildRow(context, tokens, narrow: narrow),
        FushiAnimatedSize(
          duration: motion.spatialDefault.duration,
          curve: motion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: busy
              ? Padding(
                  key: const ValueKey<String>('extension_tile_busy_progress'),
                  padding: EdgeInsets.fromLTRB(
                    horizontal,
                    0,
                    horizontal,
                    tokens.spacing.gap,
                  ),
                  child: const FushiLinearProgressIndicator(),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context,
    FushiDesignTokens tokens, {
    required bool narrow,
  }) {
    final List<Widget> actions = <Widget>[
      if (secondaryLabel != null)
        _actionButton(secondaryLabel!, onSecondary, secondaryStyle),
      if (primaryLabel != null)
        _actionButton(primaryLabel!, onPrimary, primaryStyle),
    ];
    final List<Widget> trailingChildren = <Widget>[
      if (enabled != null)
        FushiSwitch.adaptive(value: enabled!, onChanged: onEnabledChanged),
      if (!narrow) ...actions,
    ];
    final bool structured =
        metaChips.isNotEmpty || downloadsLabel != null || details != null;
    final bool compactActions = narrow && actions.isNotEmpty;
    final Widget? subtitleBlock = structured || compactActions
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (metaChips.isNotEmpty || downloadsLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: _ExtensionMetaLine(
                    parts: metaChips,
                    downloadsLabel: downloadsLabel,
                  ),
                ),
              if (subtitle != null) subtitle!,
              if (details != null) details!,
              if (compactActions) ...<Widget>[
                const SizedBox(height: 6),
                Wrap(
                  key: const ValueKey<String>(
                    'manga_extension_tile_compact_actions',
                  ),
                  spacing: 8,
                  runSpacing: 6,
                  children: actions,
                ),
              ],
            ],
          )
        : subtitle;
    return FushiListItem(
      // 一行副标题 + 图标已经自带高度；rowVertical(12) 是给两行副标题
      // 留的，这里收到 gap(8)，行高从 ~89 降到 ~62。
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal - 4,
        vertical: tokens.spacing.gap,
      ),
      titleMaxLines: 2,
      subtitleMaxLines: subtitleMaxLines,
      leading: _ExtensionIcon(url: iconUrl ?? '', title: title),
      // 标题 + 徽标用 Wrap 而不是 Row：多列目录里卡片窄、尾部开关 + 按钮又占去
      // 一大截，标题区常只剩 ~150px，「NSFW」「有更新」两枚定宽徽标在 Row 里
      // 塞不下就横向溢出；Wrap 下放不下的徽标换到标题下一行。
      title: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text(title),
          if (contentWarning) ...<Widget>[
            // M3E：error tonal 小胶囊（errorContainer 底 + onErrorContainer
            // 字）；Apple 是空心胶囊 + 系统红字。
            FushiTag(
              key: const ValueKey<String>('extension_tile_nsfw_badge'),
              text: t.extension_nsfw_badge,
              tone: FushiTagTone.error,
              dense: true,
            ),
          ],
          if (updateAvailable) ...<Widget>[
            FushiTag(
              key: const ValueKey<String>('extension_tile_update_badge'),
              text: t.extension_update_available,
              tone: FushiTagTone.accent,
              dense: true,
            ),
          ],
        ],
      ),
      subtitle: subtitleBlock,
      trailing: trailingChildren.isEmpty
          ? null
          : Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: trailingChildren,
            ),
    );
  }

  /// 动作按钮：M3E xs 档（32 高；触摸端命中区由主题的 tapTargetSize 补到 48）。
  static Widget _actionButton(
    String label,
    VoidCallback? onPressed,
    ExtensionTileActionStyle style,
  ) {
    final Widget child = Text(label);
    const FushiButtonSize size = FushiButtonSize.xs;
    return switch (style) {
      ExtensionTileActionStyle.filled => FushiFilledButton(
        size: size,
        onPressed: onPressed,
        child: child,
      ),
      ExtensionTileActionStyle.tonal => FushiFilledButton.tonal(
        size: size,
        onPressed: onPressed,
        child: child,
      ),
      ExtensionTileActionStyle.outlined => FushiOutlinedButton(
        size: size,
        onPressed: onPressed,
        child: child,
      ),
      ExtensionTileActionStyle.text => FushiTextButton(
        size: size,
        onPressed: onPressed,
        child: child,
      ),
    };
  }
}

/// 扩展卡片副标题里的一行元信息：语言 / 版本 / lib 点分成纯文字 + 下载量。
///
/// 每个片段仍是独立的 [Text]（窄卡里按片段整体换行，不会把版本号拆成两半）；
/// 片段之间的「·」是装饰，读屏不念。
class _ExtensionMetaLine extends StatelessWidget {
  const _ExtensionMetaLine({required this.parts, required this.downloadsLabel});

  final List<String> parts;
  final String? downloadsLabel;

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
    final TextStyle? style = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: color);
    final List<String> visible = <String>[
      for (final String part in parts)
        if (part.trim().isNotEmpty) part.trim(),
    ];
    final String? downloads = downloadsLabel;
    final List<InlineSpan> pieces = <InlineSpan>[
      for (final String part in visible) TextSpan(text: part),
      if (downloads != null) ...<InlineSpan>[
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(end: 2),
            child: FushiIcon(FushiIcons.download, size: 14, color: color),
          ),
        ),
        TextSpan(text: downloads),
      ],
    ];
    // 固定一行、放不下省略：多列目录里同一行卡片要等高，元信息折成两行（已装
    // 卡尾部多了开关 + 卸载 + 更新，留给文字的宽度更窄）会把卡片撑得参差。
    final List<String> spoken = <String>[...visible, ?downloads];
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          for (int i = 0; i < pieces.length; i++) ...<InlineSpan>[
            if (i > 0) const TextSpan(text: '  ·  '),
            pieces[i],
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
      semanticsLabel: spoken.join(', '),
    );
  }
}

/// 把「表头 + 若干扩展行」拍平的目录行表切成分组：返回每一行在所属分组里的
/// （组内位置, 组内总行数）。[isHeader] 逐行标明是不是仓库表头；表头是本组第
/// 0 行，后面跟到下一个表头之前的扩展行依次 1、2…。表头之前没有表头的行自成
/// 一组。漫画 / 视频（Mihon）与小说（LNReader）的扩展目录共用。
List<(int, int)> extensionGroupSlots(Iterable<bool> isHeader) {
  final List<bool> headers = isHeader.toList(growable: false);
  final List<(int, int)> slots = List<(int, int)>.filled(headers.length, (
    0,
    1,
  ));
  int start = 0;
  while (start < headers.length) {
    int end = start + 1;
    while (end < headers.length && !headers[end]) {
      end++;
    }
    final int count = end - start;
    for (int i = start; i < end; i++) {
      slots[i] = (i - start, count);
    }
    start = end;
  }
  return slots;
}

/// 扩展卡片在多列目录里的最小宽度：再窄就按 [MangaExtensionManagementTile.
/// compactActionsBreakpoint] 把动作挪到第二行，卡片会变高变碎，不如少一列。
const double kExtensionCardMinWidth = 420;

/// 扩展目录的列数：按可用宽度放下几张 [kExtensionCardMinWidth] 宽的卡片，
/// 至少 1 列、至多 3 列（再多一行扫不过来）。
int extensionCatalogColumns(double width, {double gap = 8}) {
  if (!width.isFinite || width <= 0) return 1;
  final int columns = ((width + gap) / (kExtensionCardMinWidth + gap)).floor();
  return columns.clamp(1, 3);
}

/// 把目录行表排成「显示行」：仓库表头独占一行；表头之间的扩展按 [columns] 个
/// 一组并成一行。返回每个显示行包含的原始行下标。纯函数，便于测试。
List<List<int>> extensionCatalogLines(List<bool> isHeader, int columns) {
  final int perLine = columns < 1 ? 1 : columns;
  final List<List<int>> lines = <List<int>>[];
  List<int>? open;
  for (int i = 0; i < isHeader.length; i++) {
    if (isHeader[i]) {
      lines.add(<int>[i]);
      open = null;
      continue;
    }
    if (open == null || open.length >= perLine) {
      open = <int>[i];
      lines.add(open);
    } else {
      open.add(i);
    }
  }
  return lines;
}

/// 扩展目录的懒建 sliver：仓库表头整行，扩展卡片在宽屏并成多列（窄屏单列）。
///
/// 🔴 仍然是 [SliverList.builder]（BUG-1441：keiyoushi 一家 1900+ 条，必须懒建）：
/// 多列不是 [SliverGrid]——卡片高度不一（「包含的源」可展开），网格的定高格子
/// 装不下；这里把同一显示行的几张卡放进一个顶对齐的 [Row]，行高随最高的那张。
/// 每张卡自带身份 key（调用方给），同一行内换位不串状态。
class ExtensionCatalogSliver extends StatelessWidget {
  const ExtensionCatalogSliver({
    required this.isHeader,
    required this.itemBuilder,
    super.key,
  });

  /// 逐行：是不是仓库表头（表头独占一行、不并列）。
  final List<bool> isHeader;
  final Widget Function(BuildContext context, int index) itemBuilder;

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return FushiSliverWidthBuilder(
      builder: (BuildContext context, double crossAxisExtent) {
        final int columns = extensionCatalogColumns(crossAxisExtent, gap: gap);
        final List<List<int>> lines = extensionCatalogLines(isHeader, columns);
        return SliverList.builder(
          itemCount: lines.length,
          itemBuilder: fushiStaggeredItemBuilder((
            BuildContext context,
            int index,
          ) {
            final List<int> line = lines[index];
            if (columns == 1 || isHeader[line.first]) {
              return itemBuilder(context, line.first);
            }
            // 同一显示行的卡片等高（用户 2026-11-16「高度不一致」：一张多了
            // 「展开全部 N 个源」、另一张没有，并排时底边参差）。不用
            // IntrinsicHeight（卡片内部有 LayoutBuilder，拿不到固有尺寸），也不用
            // `Table` + `TableCellVerticalAlignment.fill`——fill 格不参与行高，
            // 整行全是 fill 时行高为 0，卡片被压成 0 高、各行叠在同一处，目录
            // 「打不开」。[ExtensionCatalogRow] 先按定宽松高排出每张卡，再以最高
            // 那张的高度把整行拉齐。
            return ExtensionCatalogRow(
              columns: columns,
              gap: gap,
              children: <Widget>[
                for (final int item in line) itemBuilder(context, item),
              ],
            );
          }),
        );
      },
    );
  }
}

/// 扩展目录的一个多列显示行：[columns] 个等宽槽位（槽间 [gap]），子项依次占
/// 前几个槽（不足 [columns] 个时右侧留空），**整行等高**——先以「定宽、高度
/// 不限」排出每个子项，取最高者，再以该高度给全部子项紧约束重排。
///
/// 子项可以自带 [LayoutBuilder]（不要求固有尺寸）；行高恒为最高子项的高度，
/// 不会塌成 0。
class ExtensionCatalogRow extends MultiChildRenderObjectWidget {
  const ExtensionCatalogRow({
    required this.columns,
    required this.gap,
    required super.children,
    super.key,
  }) : assert(columns >= 1);

  final int columns;
  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderExtensionCatalogRow(
        columns: columns,
        gap: gap,
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderExtensionCatalogRow renderObject,
  ) {
    renderObject
      ..columns = columns
      ..gap = gap
      ..textDirection = Directionality.of(context);
  }
}

class _ExtensionCatalogRowParentData
    extends ContainerBoxParentData<RenderBox> {}

class _RenderExtensionCatalogRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _ExtensionCatalogRowParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _ExtensionCatalogRowParentData
        > {
  _RenderExtensionCatalogRow({
    required int columns,
    required double gap,
    required TextDirection textDirection,
  }) : _columns = columns,
       _gap = gap,
       _textDirection = textDirection;

  int get columns => _columns;
  int _columns;
  set columns(int value) {
    if (value == _columns) return;
    _columns = value;
    markNeedsLayout();
  }

  double get gap => _gap;
  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _ExtensionCatalogRowParentData) {
      child.parentData = _ExtensionCatalogRowParentData();
    }
  }

  @override
  void performLayout() {
    final double width = constraints.maxWidth;
    final double slot = math.max(0, (width - gap * (columns - 1)) / columns);
    double height = 0;
    RenderBox? child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tightFor(width: slot), parentUsesSize: true);
      height = math.max(height, child.size.height);
      child = childAfter(child);
    }
    int index = 0;
    child = firstChild;
    while (child != null) {
      child.layout(BoxConstraints.tightFor(width: slot, height: height));
      final double start = index * (slot + gap);
      (child.parentData! as _ExtensionCatalogRowParentData).offset = Offset(
        textDirection == TextDirection.rtl ? width - start - slot : start,
        0,
      );
      index++;
      child = childAfter(child);
    }
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// 扩展目录里超过这个条数的仓库分组默认收起。
///
/// 不是拍脑袋的魔数，编码的是一条产品规则：**一眼扫得完的分组就没必要收起**。
/// 装了三五个扩展的自建仓库全收起来只会让用户多点一下；而 keiyoushi 一家就
/// 1900+ 个扩展，铺开时这一页除了滚动什么也做不了（用户「这里支持下根据仓库
/// 折叠」）。收起态下表头仍显示扩展条数，不会让人以为列表空了。漫画 / 视频
/// （Mihon）与小说（LNReader）的扩展目录共用这一条。
const int kExtensionStoreAutoCollapseThreshold = 20;

/// 名字取色的拼贴色块配色（与 [FushiGeneratedCover] / 拼贴色块同一套 HSL）。
/// 墨水屏退成主题中性色。
FushiCoverBlockColors extensionMonogramColors(
  BuildContext context,
  String name,
) {
  final ThemeData theme = Theme.of(context);
  return isEinkTheme(context)
      ? FushiCoverBlockColors.resolve(theme, null)
      : FushiCoverBlockColors.fromHue(theme, fushiGeneratedCoverHue(name));
}

/// 名字首字的方形色块（仓库表头 / 已装源行的行首）：按名字取色相，深浅两套
/// 主题都可读。[dimmed] 时半透明（停用的源）。
class ExtensionMonogram extends StatelessWidget {
  const ExtensionMonogram({
    required this.name,
    super.key,
    this.size = 40,
    this.dimmed = false,
  });

  final String name;
  final double size;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors colors = extensionMonogramColors(context, name);
    final String trimmed = name.trim();
    final String initial = trimmed.isEmpty
        ? '?'
        : trimmed.characters.first.toUpperCase();
    return ExcludeSemantics(
      child: AnimatedOpacity(
        opacity: dimmed ? 0.45 : 1,
        duration: context.fushiMotion.effectsDefault.duration,
        curve: context.fushiMotion.effectsDefault.curve,
        child: SizedBox.square(
          dimension: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.container,
              borderRadius: FushiM3eShape.smallRadius,
            ),
            child: Center(
              child: Text(
                initial,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colors.onContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 扩展目录的仓库分组表头：一整条按仓库名取色的色块（拼贴语言）——首字色块 +
/// 仓库名 + 扩展条数 + 展开箭头。漫画 / 视频 / 小说三域的扩展页签共用，外观一致。
///
/// 条数不是装饰：收起态下这是「这个仓库到底有没有东西」的唯一线索，没有它
/// 折叠就等于让列表看起来空了。
class ExtensionStoreGroupHeader extends StatelessWidget {
  const ExtensionStoreGroupHeader({
    required this.keyPrefix,
    required this.indexUrl,
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
    super.key,
    this.groupCount,
  });

  /// 旧的分段列表形态里表头所在分组的总行数。拼贴改版后表头是独立色块、扩展
  /// 是独立卡片，此参数只为兼容保留，不再影响外观。
  final int? groupCount;

  /// 行 key 前缀（`<keyPrefix>-store-group-<indexUrl>`）。
  final String keyPrefix;

  /// key 用 indexUrl 而不是显示名：页面顶部的仓库**管理**卡也画着同一个 name，
  /// 按名字定位会撞上那张卡（它没有 onTap，点了什么都不会发生）。
  final String indexUrl;
  final String label;
  final int count;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final FushiSpringSpec spring = context.fushiMotion.spatialFast;
    final FushiCoverBlockColors colors = extensionMonogramColors(
      context,
      label,
    );
    final String trimmed = label.trim();
    final String initial = trimmed.isEmpty
        ? '?'
        : trimmed.characters.first.toUpperCase();
    final Widget row = FushiListItem(
      key: ValueKey<String>('$keyPrefix-store-group-$indexUrl'),
      onTap: onTap,
      leading: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 40,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.onContainer.withValues(alpha: 0.12),
              borderRadius: FushiM3eShape.smallRadius,
            ),
            child: Center(
              child: Text(
                initial,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: colors.onContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
      title: Text(
        label,
        style: theme.textTheme.titleMedium?.copyWith(
          color: colors.onContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        t.mihon_store_extension_count(count: count),
        style: theme.textTheme.bodySmall?.copyWith(
          color: colors.onContainer.withValues(alpha: 0.78),
        ),
      ),
      trailing: AnimatedRotation(
        turns: expanded ? 0.5 : 0,
        duration: spring.duration,
        curve: spring.curve,
        child: FushiIcon(FushiIcons.expandMore, color: colors.onContainer),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: tokens.spacing.gap),
      child: FushiCard(
        margin: EdgeInsets.only(bottom: tokens.spacing.gap),
        padding: EdgeInsets.zero,
        color: colors.container,
        child: row,
      ),
    );
  }
}

/// 筛选的一个选项：值 + 显示文案。
typedef ExtensionFilterOption<T> = ({T value, String label});

/// Shared responsive search + store + language filters for extension catalogs.
///
/// 拼贴改版形态（2026-11-16）：一条标准 [FushiSearchBar] + 同一行（窄屏换到下一
/// 行）的几枚下拉筛选胶囊（[LibraryFilterDropdown]，与库页工具行同一组件）——
/// 「仓库」（给了 [stores] 且多于一个仓库时才出现）、「语言」与调用方给的
/// [extraFilters]（最低下载量）。此前语言是一整行几十个横滚 chip，宽屏上也被切掉
/// 一半；收成下拉后一行放得下全部维度。
///
/// key：胶囊 `<keyPrefix>_store_filter` / `<keyPrefix>_language_filter`；菜单项沿用
/// 旧 chip 的 `<keyPrefix>_language_<code>`（「全部」= `_*`）与
/// `<keyPrefix>_store_<indexUrl>`。
class MangaExtensionFilters extends StatelessWidget {
  const MangaExtensionFilters({
    required this.languages,
    required this.selectedLanguage,
    required this.languageLabel,
    required this.allLanguagesLabel,
    required this.searchHint,
    required this.searchController,
    required this.searchQuery,
    required this.onLanguageChanged,
    required this.onSearchChanged,
    required this.onSearchCleared,
    super.key,
    this.keyPrefix = 'manga_extension',
    this.stores = const <ExtensionFilterOption<String>>[],
    this.selectedStore = '*',
    this.onStoreChanged,
    this.storeLabel,
    this.extraFilters = const <Widget>[],
  });

  final List<String> languages;
  final String selectedLanguage;
  final String languageLabel;
  final String allLanguagesLabel;
  final String searchHint;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onLanguageChanged;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onSearchCleared;
  final String keyPrefix;

  /// 可选的仓库筛选（值 = 仓库 indexUrl）。`'*'` 是「全部仓库」。
  final List<ExtensionFilterOption<String>> stores;
  final String selectedStore;
  final ValueChanged<String>? onStoreChanged;

  /// 仓库胶囊的维度名；缺省「仓库」。
  final String? storeLabel;

  /// 排在语言之后的其它筛选胶囊（[ExtensionMinDownloadsFilter]）。
  final List<Widget> extraFilters;

  /// 搜索框与筛选胶囊并排所需的最小宽度；更窄时胶囊换到搜索框下一行。
  static const double inlineBreakpoint = 720;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<String>? onStoreChanged = this.onStoreChanged;
    final bool showStores = onStoreChanged != null && stores.length > 1;
    final String effectiveStore =
        stores.any(
          (ExtensionFilterOption<String> store) => store.value == selectedStore,
        )
        ? selectedStore
        : '*';
    final String effectiveLanguage = languages.contains(selectedLanguage)
        ? selectedLanguage
        : '*';
    final Map<String, String> storeLabels = <String, String>{
      for (final ExtensionFilterOption<String> store in stores)
        store.value: store.label,
    };
    final List<Widget> filters = <Widget>[
      if (showStores)
        LibraryFilterDropdown<String>(
          key: ValueKey<String>('${keyPrefix}_store_filter'),
          value: effectiveStore == '*' ? null : effectiveStore,
          options: <String>[
            for (final ExtensionFilterOption<String> store in stores)
              store.value,
          ],
          labelOf: (String value) => storeLabels[value] ?? value,
          title: storeLabel ?? t.media_import_segment_stores,
          allLabel: t.extension_filter_all_stores,
          itemKeyOf: (String? value) =>
              ValueKey<String>('${keyPrefix}_store_${value ?? '*'}'),
          onSelected: (String? value) => onStoreChanged(value ?? '*'),
        ),
      if (languages.isNotEmpty)
        LibraryFilterDropdown<String>(
          key: ValueKey<String>('${keyPrefix}_language_filter'),
          value: effectiveLanguage == '*' ? null : effectiveLanguage,
          options: languages,
          labelOf: onlineSourceLanguageLabel,
          title: languageLabel,
          allLabel: allLanguagesLabel,
          itemKeyOf: (String? value) =>
              ValueKey<String>('${keyPrefix}_language_${value ?? '*'}'),
          onSelected: (String? value) => onLanguageChanged(value ?? '*'),
        ),
      ...extraFilters,
    ];
    final Widget search = FushiSearchBar(
      fieldKey: ValueKey<String>('${keyPrefix}_search_field'),
      controller: searchController,
      hintText: searchHint,
      onQueryChanged: onSearchChanged,
      onClear: onSearchCleared,
    );
    const double gap = 8;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (filters.isEmpty) return search;
        if (constraints.maxWidth >= inlineBreakpoint) {
          return Row(
            children: <Widget>[
              Expanded(child: search),
              for (final Widget filter in filters) ...<Widget>[
                const SizedBox(width: gap),
                filter,
              ],
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            search,
            const SizedBox(height: gap),
            Wrap(spacing: gap, runSpacing: gap, children: filters),
          ],
        );
      },
    );
  }
}

class _ExtensionIcon extends StatelessWidget {
  const _ExtensionIcon({required this.url, required this.title});

  final String url;
  final String title;

  /// 有图标和没图标的行必须等宽起排：占位图标是 24、网络图标是 32 时，
  /// 同一列表里两种行的标题左缘差 8px，扫下来像没对齐。统一成一个固定
  /// 40×40 的圆角方块（M3E 列表行首尺寸），图标缺失时方块里居中放占位符。
  /// 方块底色按扩展名取色（拼贴色块同一套 HSL），一屏卡片不再是一片灰。
  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final FushiCoverBlockColors colors = extensionMonogramColors(
      context,
      title,
    );
    final Widget fallback = Center(
      child: FushiIcon(
        FushiIcons.browserExtension,
        size: 20,
        color: colors.onContainer,
      ),
    );
    return SizedBox.square(
      dimension: _size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.container,
          borderRadius: FushiM3eShape.smallRadius,
        ),
        child: url.isEmpty
            ? fallback
            : ClipRRect(
                borderRadius: FushiM3eShape.smallRadius,
                // 🔴 不要换回 Image.network（BUG-1715）：NetworkImage 走 Flutter
                // 内部 HttpClient，接不进应用代理出口；桌面上索引经代理能拉到、
                // 图标直连 raw.githubusercontent.com 却失败，列表就全是占位图标。
                child: Image(
                  image: AppHttpImage(url),
                  width: _size,
                  height: _size,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => fallback,
                  loadingBuilder:
                      (_, Widget child, ImageChunkEvent? progress) =>
                          progress == null ? child : fallback,
                ),
              ),
      ),
    );
  }
}
