/// 音乐「在线 › 来源」的 Cupertino 版（用户 2026-11-24「来源布局有点怪」→「看看和
/// 歌单一样吧」）：与曲库「歌单」同一套 Apple Music 资料库式分组列表
/// （`apple_music_list_layout.dart`）——
///
/// - 「音源」组：段头（粗体段名 + 右侧「编辑 / 完成」文字动作，段头自带分组间距）；
///   每行 与封面同尺寸的图标方块 + 名称 + 类型说明 + 行尾 Apple 开关（整行点 / Enter
///   也切换）；编辑态行尾换 ≡ 重排把手（拖动 / Alt+↑↓ / 读屏「上移 / 下移」）；
///   Apple Music 开着时多一条与名称对齐的「地区」子行；组末强调色「添加来源…」动作行，
///   组脚一行说明。
/// - 「歌词来源」另起一组（[MusicLyricsProvidersBody] 的 Apple 列表分支）。
/// - macOS 档内容限宽居中。
///
/// 只在 `isGlassDesign` 为真时由 `MusicOnlineSourcesView` 使用；状态与写回仍在那一个
/// State 里（这里只收行数据与回调），M3E 一侧不经过这里。设置里的「歌词来源」页
/// 仍是 Apple「设置」式 inset grouped（[appleMusicSourcesSeparated] /
/// [appleMusicSourcesFootnote]）。
library;

import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/import/apple/apple_import_rows.dart'
    show AppleImportSectionAction;
import 'package:fushi/src/pages/implementations/music/apple/apple_music_list_layout.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiLinearProgressIndicator;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics, fushiHairline;
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSwitch;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// macOS 档「来源」内容的最大宽（与系统设置的表单栏同量级，乘 macOS 档缩放）。
const double kAppleMusicSourcesMaxWidth = 640;

/// 「音源」组的一行。
typedef AppleMusicSourceRowData = ({
  String key,
  String title,
  String subtitle,
  IconData icon,
  bool on,

  /// Apple Music：开着时下面挂「地区」子行。
  bool appleMusic,
});

/// 组内行与行之间的细线左缩进：与行内文字左缘对齐（行距 + 图标块 + 间距）。
double appleMusicSourcesSeparatorInset(BuildContext context) {
  final FushiAppleMetrics m = FushiAppleMetrics.of(context);
  return m.rowHorizontal +
      m.iconTileSize +
      FushiDesignTokens.of(context).spacing.gap +
      4;
}

/// 组脚说明（footnote 字样，与行文字左缘同一条线）。
Widget appleMusicSourcesFootnote(BuildContext context, String text) {
  final FushiAppleMetrics m = FushiAppleMetrics.of(context);
  return Padding(
    padding: EdgeInsets.symmetric(horizontal: m.rowHorizontal),
    child: Text(text, style: m.footnoteStyle(context)),
  );
}

/// 编辑态行尾的 ≡ 重排把手：拖动（[FushiReorderableDragHandle]）、Alt+↑/↓、读屏
/// 「上移 / 下移」三条路径同一个 [onReorder]（与导入页来源行同一约定）。
class AppleMusicReorderHandle extends StatelessWidget {
  const AppleMusicReorderHandle({
    super.key,
    required this.index,
    required this.count,
    required this.onReorder,
  });

  final int index;
  final int count;
  final void Function(int from, int to) onReorder;

  void _move(int delta) {
    final int to = index + delta;
    if (to < 0 || to >= count) return;
    onReorder(index, to);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors colors = appleColorsOf(context);
    return Semantics(
      label: t.tag_manage_reorder_hint,
      customSemanticsActions: <CustomSemanticsAction, VoidCallback>{
        if (index > 0)
          CustomSemanticsAction(label: t.music_lyrics_providers_move_up): () =>
              _move(-1),
        if (index < count - 1)
          CustomSemanticsAction(
            label: t.music_lyrics_providers_move_down,
          ): () =>
              _move(1),
      },
      child: FocusableActionDetector(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): _MoveIntent(
            -1,
          ),
          SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): _MoveIntent(
            1,
          ),
        },
        actions: <Type, Action<Intent>>{
          _MoveIntent: CallbackAction<_MoveIntent>(
            onInvoke: (_MoveIntent intent) {
              _move(intent.delta);
              return null;
            },
          ),
        },
        mouseCursor: SystemMouseCursors.grab,
        child: FushiReorderableDragHandle(
          child: SizedBox.square(
            dimension: 44,
            child: Center(
              child: FushiIcon(
                FushiIcons.dragHandle,
                size: 20,
                color: colors.tertiaryLabel,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MoveIntent extends Intent {
  const _MoveIntent(this.delta);

  final int delta;
}

/// 组内一行上方的细线（第一行不画）。
Widget appleMusicSourcesSeparated(
  BuildContext context, {
  required int index,
  required Widget child,
}) {
  if (index == 0) return child;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Padding(
        padding: EdgeInsetsDirectional.only(
          start: appleMusicSourcesSeparatorInset(context),
        ),
        child: Container(
          height: fushiHairline(context),
          color: appleColorsOf(context).separator,
        ),
      ),
      child,
    ],
  );
}

/// 「来源」页 Apple 版。
class AppleMusicSourcesLayout extends StatefulWidget {
  const AppleMusicSourcesLayout({
    super.key,
    required this.rows,
    required this.storefront,
    required this.storefronts,
    required this.onToggle,
    required this.onReorder,
    required this.onStorefront,
    required this.addKey,
    required this.onAdd,
    required this.padding,
    this.lyrics,
  });

  /// null = 还在加载。
  final List<AppleMusicSourceRowData>? rows;
  final String storefront;
  final List<String> storefronts;
  final void Function(int index, bool on) onToggle;
  final void Function(int from, int to) onReorder;
  final ValueChanged<String> onStorefront;

  /// 「添加来源」行的 key（宿主拿它当 pull-down 的锚点）。
  final Key addKey;
  final VoidCallback onAdd;
  final EdgeInsets padding;

  /// 「歌词来源」组（null = 本平台用不了插件歌词，不出这一组）。
  final Widget? lyrics;

  @override
  State<AppleMusicSourcesLayout> createState() =>
      _AppleMusicSourcesLayoutState();
}

class _AppleMusicSourcesLayoutState extends State<AppleMusicSourcesLayout> {
  bool _editing = false;

  Widget _row(
    BuildContext context,
    List<AppleMusicSourceRowData> rows,
    int i,
    bool editing,
  ) {
    final AppleMusicSourceRowData r = rows[i];
    final String selected = widget.storefronts.contains(widget.storefront)
        ? widget.storefront
        : widget.storefronts.first;
    final bool region = r.appleMusic && r.on && !editing;
    final Widget main = AppleMusicListRow(
      key: ValueKey<String>(
        editing ? 'music-source-row-${r.key}' : 'music-source-toggle-${r.key}',
      ),
      icon: r.icon,
      title: r.title,
      subtitle: r.subtitle,
      // 整行点 / Enter = 切开关（Apple「设置」开关行）；编辑态整行不响应，只拖把手。
      onTap: editing ? null : () => widget.onToggle(i, !r.on),
      trailing: editing
          ? AppleMusicReorderHandle(
              key: ValueKey<String>('music-source-handle-${r.key}'),
              index: i,
              count: rows.length,
              onReorder: widget.onReorder,
            )
          : FushiSwitch(
              value: r.on,
              onChanged: (bool v) => widget.onToggle(i, v),
            ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        main,
        FushiAnimatedSize(
          duration: fushiMotionDuration(context, FushiMotion.short),
          curve: FushiMotion.standard,
          alignment: Alignment.topCenter,
          child: region
              // 从属子行：文字与父行文字左缘对齐（Apple「设置」的从属行）。
              ? AppleMusicListSubRow(
                  child: AdaptiveSettingsPickerRow<String>(
                    key: const ValueKey<String>(
                      'music-sources-apple-music-region',
                    ),
                    title: t.music_sources_region,
                    subtitle: t.music_apple_music_storefront_hint,
                    options: <AdaptiveSettingsPickerOption<String>>[
                      for (final String sf in widget.storefronts)
                        AdaptiveSettingsPickerOption<String>(
                          value: sf,
                          label: sf.toUpperCase(),
                        ),
                    ],
                    selected: selected,
                    onChanged: widget.onStorefront,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleMetrics m = FushiAppleMetrics.of(context);
    final List<AppleMusicSourceRowData>? rows = widget.rows;
    final bool editing = _editing && (rows?.isNotEmpty ?? false);
    final Widget? lyrics = widget.lyrics;
    // 「音源」一组：段头（+「编辑 / 完成」）→ 开关行 → 「添加来源…」→ 组脚说明。
    final Widget sources = Column(
      key: const ValueKey<String>('music-sources-group'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppleMusicListSectionHeader(
          title: t.music_sources_section_title,
          actions: <Widget>[
            if (rows != null && rows.length >= 2)
              AppleImportSectionAction(
                key: const ValueKey<String>('music-sources-edit'),
                label: editing ? t.dialog_done : t.dialog_edit,
                onTap: () => setState(() => _editing = !editing),
              ),
          ],
        ),
        if (rows == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: FushiLinearProgressIndicator(),
          )
        else if (rows.isNotEmpty)
          FushiReorderableColumn(
            itemCount: rows.length,
            useDragHandles: true,
            keyForIndex: (int i) =>
                ValueKey<String>('music-source-${rows[i].key}'),
            onReorder: widget.onReorder,
            itemBuilder: (BuildContext context, int i) =>
                _row(context, rows, i, editing),
          ),
        AppleMusicListActionRow(
          key: widget.addKey,
          icon: FushiIcons.add,
          title: '${t.music_sources_add}…',
          separator: false,
          onTap: editing ? null : widget.onAdd,
        ),
        AppleMusicListNote(t.music_sources_online_hint),
      ],
    );
    return SingleChildScrollView(
      key: const ValueKey<String>('music-online-sources-view'),
      padding: widget.padding,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: m.desktop
                ? kAppleMusicSourcesMaxWidth * m.scale
                : double.infinity,
          ),
          // 段与段之间不另加间距：段头自带分组间距（[AppleMusicListSectionHeader]）。
          child: FushiEntranceScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                FushiStaggeredEntrance(index: 0, child: sources),
                if (lyrics != null)
                  FushiStaggeredEntrance(index: 1, child: lyrics),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
