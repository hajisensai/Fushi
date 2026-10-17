import 'package:material_ui/material_ui.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/fushi_page_placeholders.dart';
import 'package:fushi/src/utils/components/fushi_horizontal_edge_fade.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart'
    show FushiDragHandle;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 编辑「单个本地音频库」的子来源：拖拽调整优先级顺序 + 逐源启用/禁用。
///
/// 进入时把 [savedPrefs]（已存的偏好）与 [listSources]（库内实际枚举到的 source）
/// 合并：存里有的保序、库里新出现的追加（默认启用）、库里已消失的丢弃。关闭时
/// 通过 [onApply] 即时持久化（不走主对话框的批量保存）。
class LocalAudioSourcesDialog extends StatefulWidget {
  const LocalAudioSourcesDialog({
    required this.dbPath,
    required this.savedPrefs,
    required this.listSources,
    required this.onApply,
    super.key,
  });

  final String dbPath;
  final List<LocalAudioSourcePref> savedPrefs;
  final Future<List<String>> Function() listSources;
  final Future<void> Function(List<LocalAudioSourcePref>) onApply;

  /// 合并已存偏好与库内实际来源：保序 + 追加新源（默认启用）+ 丢弃消失源。
  @visibleForTesting
  static List<LocalAudioSourcePref> merge(
    List<LocalAudioSourcePref> saved,
    List<String> discovered,
  ) {
    final Set<String> known = saved
        .map((LocalAudioSourcePref s) => s.name)
        .toSet();
    return <LocalAudioSourcePref>[
      for (final LocalAudioSourcePref s in saved)
        if (discovered.contains(s.name)) s, // 保序、丢弃已消失的
      for (final String name in discovered)
        if (!known.contains(name)) LocalAudioSourcePref(name: name), // 追加新源
    ];
  }

  @override
  State<LocalAudioSourcesDialog> createState() =>
      _LocalAudioSourcesDialogState();
}

class _LocalAudioSourcesDialogState extends State<LocalAudioSourcesDialog>
    with FushiPagePlaceholders<LocalAudioSourcesDialog> {
  List<LocalAudioSourcePref>? _prefs; // null = 仍在枚举

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<String> discovered = await widget.listSources();
    if (!mounted) return;
    setState(
      () =>
          _prefs = LocalAudioSourcesDialog.merge(widget.savedPrefs, discovered),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double maxHeight = (MediaQuery.of(context).size.height * 0.55).clamp(
      128.0,
      420.0,
    );

    return FushiDialogFrame(
      maxWidth: 480,
      maxHeightFactor: 0.92,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.local_audio_source_order_title,
        leadingIcon: FushiIcons.audio,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        // 整体可滚动：FushiReorderableColumn 自身不带滚动（内部 Stack + Column.min），
        // 行数多到超过 maxHeight 时会 RenderFlex 溢出（出框）且无法滚动看到下面的行
        // （BUG-445）。外层套 SingleChildScrollView：内容超高时整体滚动而非溢出，行少
        // 时仍按内容收缩。与「管理音频来源」主对话框（dictionary_settings_dialog_page）
        // 同款修法。拖拽重排不与滚动冲突：触摸屏用 DelayedMultiDrag（长按起拖，快速滑动
        // 仍归滚动）；鼠标用滚轮（PointerScroll）滚动、按下拖动起拖（ImmediateMultiDrag），
        // 二者各走不同指针序列、不争用手势竞技场（见 FushiReorderableColumn 类注释）。
        body: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: double.maxFinite,
            maxHeight: maxHeight,
          ),
          // 溢出时上 / 下端柔和淡出（只淡还有内容的那一侧），不再硬切最后一行。
          child: FushiHorizontalEdgeFade(
            axis: Axis.vertical,
            child: SingleChildScrollView(child: _buildBody(tokens)),
          ),
        ),
        footer: Align(
          alignment: Alignment.centerRight,
          child: adaptiveDialogAction(
            context: context,
            onPressed: () {
              final List<LocalAudioSourcePref>? prefs = _prefs;
              if (prefs != null) widget.onApply(prefs);
              Navigator.pop(context);
            },
            child: Text(t.dialog_close),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(FushiDesignTokens tokens) {
    final List<LocalAudioSourcePref>? prefs = _prefs;
    if (prefs == null) {
      return buildLoading(padding: const EdgeInsets.all(24));
    }
    if (prefs.isEmpty) {
      // M3E 空状态：72 色块图标 + 弹入（FushiPlaceholderMessage）。
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: FushiPlaceholderMessage(
          icon: FushiIcons.audio,
          message: t.local_audio_no_sources,
        ),
      );
    }
    // 用自实现的 FushiReorderableColumn（局部坐标长按拖拽），而非 SDK 的
    // ReorderableListView：后者的 Overlay 拖拽代理不认祖先 FushiAppUiScale 的
    // Transform.scale，缩放界面下长按拖拽会飞出屏幕。前者把拖拽反馈渲染在列表自身坐标系、
    // 用 globalToLocal 消掉祖先缩放 → 任意缩放下都精确跟手、零偏移且视觉一致。
    // 行尾把手的「上移 / 下移」菜单是无障碍 / 手柄重排路径。
    // M3E 分段列表：每个来源一张分段卡（首尾大圆角、行间 2），行间缝交给
    // FushiReorderableColumn 的 spacing（拖拽时缝不跟着行走）；首次出现错峰进场。
    return FushiEntranceScope(
      child: FushiReorderableColumn(
        itemCount: prefs.length,
        spacing: fushiGroupedListGap(context),
        keyForIndex: (int index) =>
            ValueKey<String>('local_audio_source_${prefs[index].name}'),
        onReorder: (int from, int to) {
          setState(() {
            final LocalAudioSourcePref item = prefs.removeAt(from);
            prefs.insert(to, item);
          });
        },
        itemBuilder: (BuildContext context, int index) {
          final LocalAudioSourcePref source = prefs[index];
          return FushiStaggeredEntrance(
            index: index,
            child: FushiGroupedListItem(
              index: index,
              count: prefs.length,
              includeGap: false,
              child: AdaptiveSettingsRow(
                title: source.name,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    FushiSwitch.adaptive(
                      value: source.enabled,
                      onChanged: (bool enabled) => setState(() {
                        prefs[index] = source.copyWith(enabled: enabled);
                      }),
                    ),
                    _buildReorderHandle(prefs, index),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 行尾重排把手：M3E drag_indicator（Apple 三横线），整行长按 / 鼠标按下即可
  /// 拖动（手势归外层 [FushiReorderableColumn]）。把手本身是可聚焦的菜单按钮：
  /// 点按 / Enter / 手柄确认弹出「上移 / 下移」，是键盘、手柄与读屏的重排路径
  /// ——取代原先常驻的两枚裸 ^ / v 箭头（首行「上移」只是变灰，见 iOS 反馈截图）。
  Widget _buildReorderHandle(List<LocalAudioSourcePref> prefs, int index) {
    if (prefs.length < 2) return const SizedBox.shrink();
    return FushiPopupMenuButton<int>(
      key: ValueKey<String>('local_audio_source_handle_${prefs[index].name}'),
      tooltip: t.local_audio_source_reorder_tooltip,
      padding: EdgeInsets.zero,
      // 命中 / 状态层与 48dp 热区同形（圆），视觉把手仍是 FushiDragHandle 原尺寸。
      borderRadius: BorderRadius.circular(kMinInteractiveDimension / 2),
      onSelected: (int delta) => _move(prefs, index, index + delta),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        PopupMenuItem<int>(
          value: -1,
          enabled: index > 0,
          child: _menuLabel(FushiIcons.expandLess, t.move_up),
        ),
        PopupMenuItem<int>(
          value: 1,
          enabled: index < prefs.length - 1,
          child: _menuLabel(FushiIcons.expandMore, t.move_down),
        ),
      ],
      // 把手视觉只有 size + 12 = 32px；触屏命中区按 M3 最小交互尺寸撑到 48dp，
      // 把手居中、视觉尺寸不变（审查 PR #2098：32px 热区低于 48dp）。
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: kMinInteractiveDimension,
          minHeight: kMinInteractiveDimension,
        ),
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: FushiDragHandle(),
        ),
      ),
    );
  }

  Widget _menuLabel(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      FushiIcon(icon, size: 20),
      const SizedBox(width: 12),
      Flexible(child: Text(label)),
    ],
  );

  void _move(List<LocalAudioSourcePref> prefs, int from, int to) {
    if (to < 0 || to >= prefs.length || to == from) return;
    setState(() {
      final LocalAudioSourcePref item = prefs.removeAt(from);
      prefs.insert(to, item);
    });
  }
}
