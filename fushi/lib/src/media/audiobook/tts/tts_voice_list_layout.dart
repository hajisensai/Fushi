/// 「朗读声音」页的版面：声音列表（行首单选 = 设为使用中、行尾删除）+ 添加声音
/// + 缓存入口，按**可用宽度**分两形态（不按平台）：
/// - 宽（≥ [kTtsWideMinWidth]）：与制作台同一副双栏骨架 [TtsTwoPaneLayout]，左侧
///   侧栏列声音（选中项 pill 高亮），右侧直接是选中声音的编辑内容；缓存常驻侧栏底部。
/// - 窄：一条分组列表，点行推进该声音的编辑页。
///
/// 纯 widget：不读 AppModel / Riverpod，页面把声音数据、详情构建与回调交进来，
/// 单测可直接挂。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/audiobook/tts/tts_two_pane_layout.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_schema_widgets.dart'
    show SettingsSectionFooter;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 列表里一个声音的展示数据。
@immutable
class TtsVoiceListEntry {
  const TtsVoiceListEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.incomplete = false,
  });

  final String id;
  final String title;

  /// 一行说明（大类 · 引擎）。
  final String subtitle;
  final IconData icon;

  /// 配置不完整 / 引擎在本平台不可用：说明行后追加警示色的「未完成」。
  final bool incomplete;
}

/// 删除声音前的确认（列表行与编辑页共用）。返回 true = 确认删除。
Future<bool> confirmTtsVoiceDelete(BuildContext context, String name) =>
    showFushiConfirmDialog(
      context: context,
      title: name,
      icon: FushiIcons.delete,
      confirmLabel: t.audiobook_tts_voice_delete,
      destructive: true,
    );

/// 宽形态下右侧实际显示的声音：[selectedId] 不在列表里时退回使用中的声音，再退回
/// 第一个；列表为空返回 null。
String? resolveTtsVoiceSelection(
  List<TtsVoiceListEntry> voices, {
  required String? selectedId,
  required String? activeId,
}) {
  bool has(String? id) =>
      id != null && voices.any((TtsVoiceListEntry v) => v.id == id);
  if (has(selectedId)) return selectedId;
  if (has(activeId)) return activeId;
  return voices.isEmpty ? null : voices.first.id;
}

class TtsVoiceListLayout extends StatelessWidget {
  const TtsVoiceListLayout({
    required this.voices,
    required this.activeId,
    required this.selectedId,
    required this.onSelect,
    required this.onOpen,
    required this.onUse,
    required this.onDelete,
    required this.onAdd,
    required this.detailBuilder,
    required this.onClearCache,
    this.cacheSubtitle,
    this.scrollController,
    super.key,
  });

  final List<TtsVoiceListEntry> voices;

  /// 使用中的声音（行首单选的选中项）。
  final String? activeId;

  /// 宽形态右侧显示的声音（见 [resolveTtsVoiceSelection]）。
  final String? selectedId;

  /// 宽形态点行：在右侧显示该声音。
  final ValueChanged<String> onSelect;

  /// 窄形态点行：推进该声音的编辑页。
  final ValueChanged<String> onOpen;

  /// 行首单选：设为使用中。
  final ValueChanged<String> onUse;

  /// 行尾删除（已确认过）。
  final ValueChanged<String> onDelete;

  /// 「添加声音」；参数是当前是否双栏（双栏下新声音直接在右侧编辑，不推页）。
  final ValueChanged<bool> onAdd;

  /// 宽形态右侧的声音编辑内容（自带滚动视图）。
  final Widget Function(BuildContext context, String id) detailBuilder;

  /// 缓存大小说明；null = 还没量出来。
  final String? cacheSubtitle;

  /// 清空缓存；null = 没有缓存可清（行置灰）。
  final VoidCallback? onClearCache;

  /// 窄形态列表的滚动控制器（交给设置页壳做页头收展）。
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          ttsUsesWideLayout(constraints.maxWidth)
          ? _buildWide(context)
          : _buildNarrow(context),
    );
  }

  Widget _voiceRow(
    BuildContext context,
    TtsVoiceListEntry voice, {
    required bool wide,
    required bool selected,
  }) => _TtsVoiceRow(
    key: ValueKey<String>('tts-voice-${voice.id}'),
    voice: voice,
    active: voice.id == activeId,
    activeId: activeId,
    wide: wide,
    selected: selected,
    onTap: () => wide ? onSelect(voice.id) : onOpen(voice.id),
    onUse: () => onUse(voice.id),
    onDelete: () async {
      if (await confirmTtsVoiceDelete(context, voice.title)) {
        onDelete(voice.id);
      }
    },
  );

  Widget _buildNarrow(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    return FushiEntranceScope(
      child: ListView(
        key: const ValueKey<String>('tts-voice-settings'),
        controller: scrollController,
        padding: EdgeInsets.fromLTRB(
          inset,
          tokens.spacing.gap + MediaQuery.paddingOf(context).top,
          inset,
          tokens.spacing.page + bottomSafeInsetOf(context),
        ),
        children: <Widget>[
          AdaptiveSettingsSection(
            key: const ValueKey<String>('tts-voice-list'),
            title: t.audiobook_tts_voices_section,
            children: <Widget>[
              for (int i = 0; i < voices.length; i++)
                FushiStaggeredEntrance(
                  index: i,
                  child: _voiceRow(
                    context,
                    voices[i],
                    wide: false,
                    selected: false,
                  ),
                ),
              AdaptiveSettingsRow(
                key: const ValueKey<String>('tts-voice-add'),
                icon: FushiIcons.add,
                showIcon: true,
                title: t.audiobook_tts_voice_add,
                onTap: () => onAdd(false),
              ),
            ],
          ),
          if (voices.isEmpty)
            SettingsSectionFooter(
              t.audiobook_tts_voice_empty,
              key: const ValueKey<String>('tts-voice-empty'),
            ),
          AdaptiveSettingsSection(
            key: const ValueKey<String>('tts-voice-cache'),
            title: t.audiobook_tts_cache_section,
            children: <Widget>[
              AdaptiveSettingsRow(
                key: const ValueKey<String>('tts-voice-cache-clear'),
                icon: FushiIcons.deleteSweep,
                showIcon: true,
                title: t.audiobook_tts_cache_clear,
                subtitle: cacheSubtitle,
                onTap: onClearCache,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWide(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? shown = resolveTtsVoiceSelection(
      voices,
      selectedId: selectedId,
      activeId: activeId,
    );
    final TextStyle? sectionStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(color: tokens.surfaces.onVariant);
    // 设置页壳把页头让位放在 padding.top 里（bodyConsumesTopPadding）：双栏不滚到
    // 页头底下，整体让开，两栏内部不再重复让位。
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: _twoPane(context, tokens, shown, sectionStyle),
      ),
    );
  }

  Widget _twoPane(
    BuildContext context,
    FushiDesignTokens tokens,
    String? shown,
    TextStyle? sectionStyle,
  ) {
    final double gap = tokens.spacing.gap;
    return TtsTwoPaneLayout(
      key: const ValueKey<String>('tts-voice-layout-wide'),
      sidebarKey: const ValueKey<String>('tts-voice-sidebar'),
      sidebar: FushiEntranceScope(
        child: ListView(
          key: const ValueKey<String>('tts-voice-sidebar-list'),
          padding: EdgeInsets.symmetric(vertical: gap),
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.card,
                gap / 2,
                tokens.spacing.card,
                gap / 2,
              ),
              child: Text(t.audiobook_tts_voices_section, style: sectionStyle),
            ),
            for (int i = 0; i < voices.length; i++)
              FushiStaggeredEntrance(
                index: i,
                child: Padding(
                  padding: EdgeInsets.only(bottom: gap / 4),
                  child: _voiceRow(
                    context,
                    voices[i],
                    wide: true,
                    selected: voices[i].id == shown,
                  ),
                ),
              ),
            FushiListItem(
              key: const ValueKey<String>('tts-voice-add'),
              leading: FushiIcon(
                FushiIcons.add,
                size: 22,
                color: tokens.surfaces.onVariant,
              ),
              title: Text(t.audiobook_tts_voice_add),
              onTap: () => onAdd(true),
            ),
            if (voices.isEmpty)
              Padding(
                key: const ValueKey<String>('tts-voice-empty'),
                padding: EdgeInsets.all(tokens.spacing.card),
                child: Text(
                  t.audiobook_tts_voice_empty,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: tokens.surfaces.onVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
      sidebarFooter: FushiListItem(
        key: const ValueKey<String>('tts-voice-cache-clear'),
        leading: FushiIcon(
          FushiIcons.deleteSweep,
          size: 22,
          color: tokens.surfaces.onVariant,
        ),
        title: Text(t.audiobook_tts_cache_clear),
        subtitle: cacheSubtitle == null ? null : Text(cacheSubtitle!),
        onTap: onClearCache,
      ),
      content: AnimatedSwitcher(
        duration: fushiMotionDuration(context, FushiMotion.medium),
        switchInCurve: FushiMotion.standard,
        switchOutCurve: FushiMotion.standard,
        child: shown == null
            ? Center(
                key: const ValueKey<String>('tts-voice-detail-empty'),
                child: Padding(
                  padding: EdgeInsets.all(tokens.spacing.page),
                  child: Text(
                    t.audiobook_tts_voice_empty,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: tokens.surfaces.onVariant,
                    ),
                  ),
                ),
              )
            : KeyedSubtree(
                key: ValueKey<String>('tts-voice-detail-$shown'),
                child: detailBuilder(context, shown),
              ),
      ),
    );
  }
}

/// 一个声音行：行首单选（设为使用中）+ 名称 / 说明 + 行尾删除（窄形态再加进入
/// 箭头）。整行、单选、删除各自可聚焦，Enter 触发。
class _TtsVoiceRow extends StatelessWidget {
  const _TtsVoiceRow({
    required this.voice,
    required this.active,
    required this.activeId,
    required this.wide,
    required this.selected,
    required this.onTap,
    required this.onUse,
    required this.onDelete,
    super.key,
  });

  final TtsVoiceListEntry voice;
  final bool active;
  final String? activeId;
  final bool wide;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onUse;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle warning = TextStyle(
      color: fushiStatusColor(context, FushiStatusTone.warning),
    );
    return FushiListItem(
      selected: selected,
      selectedShape: FushiListItemSelectedShape.pill,
      onTap: onTap,
      leading: FushiTooltip(
        message: active
            ? t.audiobook_tts_voice_active
            : t.audiobook_tts_voice_use,
        child: Semantics(
          label: t.audiobook_tts_voice_use,
          child: FushiRadio<String>(
            key: ValueKey<String>('tts-voice-use-${voice.id}'),
            value: voice.id,
            groupValue: activeId,
            onChanged: (String? _) {
              if (!active) onUse();
            },
          ),
        ),
      ),
      title: Text(voice.title),
      subtitle: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            TextSpan(text: voice.subtitle),
            if (voice.incomplete)
              TextSpan(
                text: ' · ${t.audiobook_tts_voice_incomplete_status}',
                style: warning,
              )
            else if (active)
              TextSpan(text: ' · ${t.audiobook_tts_voice_active}'),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          FushiIconButton(
            key: ValueKey<String>('tts-voice-delete-${voice.id}'),
            icon: FushiIcons.delete,
            tooltip: t.audiobook_tts_voice_delete,
            onTap: onDelete,
          ),
          if (!wide)
            if (isGlassDesign(context))
              const FushiAppleChevron()
            else
              FushiIcon(
                FushiIcons.chevronRight,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
        ],
      ),
    );
  }
}
