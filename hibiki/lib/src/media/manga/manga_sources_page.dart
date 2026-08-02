import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:hibiki/src/media/manga/online/mokuro_moe_source_row.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/media_sources_view.dart';
import 'package:hibiki/utils.dart';

/// 漫画库「来源」视图：本域**所有**来源的唯一管理处。
///
/// 三节，自上而下：
/// 1. 本地漫画扫描根（与书 / 视频共用的 [MediaSourcesView]）；
/// 2. 漫画扩展（Mihon 扩展仓库 + 安装 / 启停 / 卸载）——用户口径：「漫画扩展
///    不就是来源吗，来源设置里面加上就行了」，因此**不另开顶层 tab**；
/// 3. 在线漫画源：内置的 mokuro.moe **与**扩展提供的源并列（启停 / 排序 / 偏好 /
///    清数据 / 置顶）。
///
/// 🔴 mokuro.moe 归第 3 节，不归第 1 节（BUG-1431）：它是个网站，不是本地扫描根。
/// 之前它和「Hibiki 互联」一起挂在「本地扫描根」下，用户口径「mokuro 不应该单独
/// 显示，应该和漫画扩展同一层级」。挪进「漫画源」后它与扩展源同构——同一节、同一
/// 种开关语义（关掉 = 不在「浏览」里出现）。
///
/// 🔴 本页的滚动容器必须是 [CustomScrollView]（BUG-1441）：第 2 节要渲染整个扩展
/// 仓库（keiyoushi 有 1900+ 条），只有 sliver 才能懒建。换回 `ListView` +
/// 内嵌 `Column` 会立刻把「语言下拉一展开就卡死」带回来。
///
/// 平台差异只在**内容**：iOS / Linux 没有扩展宿主，第 2、3 节渲染成
/// `mihon_runtime_unavailable` 提示，视图本身与其它平台同构、同位。
/// `AppModel.mihonManager` 在这些平台会抛 [UnsupportedError]，故一切读它的路径
/// 都必须先过 [MihonRuntimeFactory.isSupported]。
class MangaSourcesPage extends ConsumerStatefulWidget {
  const MangaSourcesPage({
    super.key,
    this.navigation,
  });

  /// 库页视图导航条（由 `MediaLibraryShell` 传入，作为页头主内容）。
  final Widget? navigation;

  @override
  ConsumerState<MangaSourcesPage> createState() => _MangaSourcesPageState();
}

class _MangaSourcesPageState extends ConsumerState<MangaSourcesPage> {
  final GlobalKey<MediaSourcesViewState> _localSourcesKey =
      GlobalKey<MediaSourcesViewState>();
  MihonManager? _manager;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MihonRuntimeFactory.isSupported) return;
    final MihonManager manager = ref.read(appProvider).mihonManager;
    if (identical(manager, _manager)) return;
    _manager?.removeListener(_changed);
    _manager = manager..addListener(_changed);
  }

  @override
  void dispose() {
    _manager?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _clearSourceData(MangaOnlineSourceRow source) async {
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog.adaptive(
        title: Text(t.mihon_source_clear_data),
        content: Text(t.mihon_source_clear_data_hint),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: dialogContext,
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.dialog_clear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _manager!.clearSourceData(source);
    } on Object catch (error) {
      if (mounted) HibikiToast.show(msg: '$error');
    }
  }

  void _openPreferences(MangaOnlineSourceRow source) {
    showAppDialog<void>(
      context: context,
      builder: (BuildContext context) => _MihonPreferencesDialog(
        manager: _manager!,
        source: source,
      ),
    );
  }

  Future<void> _moveSource(
    MangaOnlineSourceRow source,
    int delta,
  ) async {
    final List<MangaOnlineSourceRow> rows =
        List<MangaOnlineSourceRow>.of(_manager!.sources);
    final int index = rows.indexWhere(
      (MangaOnlineSourceRow row) =>
          row.extensionPackage == source.extensionPackage &&
          row.sourceId == source.sourceId,
    );
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= rows.length) return;
    final MangaOnlineSourceRow other = rows[target];
    await _manager!.updateSourceSettings(
      source,
      sortOrder: other.sortOrder,
    );
    await _manager!.updateSourceSettings(
      other,
      sortOrder: source.sortOrder,
    );
  }

  Widget _sectionTitle(String title) => Text(
        title,
        style: Theme.of(context).textTheme.titleLarge,
      );

  /// 扩展宿主不可用时统一的占位（iOS / Linux）。结构不变，只是这一节没内容。
  Widget _unavailableNote() => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          t.mihon_runtime_unavailable,
          textAlign: TextAlign.center,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final MihonManager? manager = _manager;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context))
            HibikiPageHeader(
              title: t.media_source_manage_title,
              actions: <Widget>[
                HibikiIconButton(
                  tooltip: t.media_source_add,
                  label: t.media_source_add,
                  icon: Icons.create_new_folder_outlined,
                  onTap: () => _localSourcesKey.currentState?.addSource(),
                ),
              ],
              bottom: widget.navigation,
            ),
          Expanded(
            child: CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverMainAxisGroup(
                    slivers: <Widget>[
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _sectionTitle(t.media_source_local_roots),
                            const SizedBox(height: 8),
                            MediaSourcesView(
                              key: _localSourcesKey,
                              mediaKind: 'manga',
                            ),
                            const SizedBox(height: 28),
                            _sectionTitle(t.mihon_extensions_title),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                      if (manager == null)
                        SliverToBoxAdapter(child: _unavailableNote())
                      else
                        const MihonExtensionsPage(embedded: true),
                      SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            const SizedBox(height: 28),
                            _sectionTitle(t.mihon_sources_title),
                            const SizedBox(height: 8),
                            // 内置在线源：与扩展提供的源同节同级（见类文档）。
                            const MokuroMoeSourceRow(),
                            if (manager == null) _unavailableNote(),
                          ],
                        ),
                      ),
                      if (manager != null)
                        SliverList.builder(
                          itemCount: manager.sources.length,
                          itemBuilder: (BuildContext context, int index) =>
                              _buildOnlineSource(
                            manager,
                            manager.sources[index],
                            index,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOnlineSource(
    MihonManager manager,
    MangaOnlineSourceRow source,
    int index,
  ) {
    return HibikiCard(
      padding: EdgeInsets.zero,
      child: HibikiListItem(
        leading: Switch.adaptive(
          value: source.enabled,
          onChanged: (bool value) => unawaited(
            manager.updateSourceSettings(source, enabled: value),
          ),
        ),
        title: Text(source.name),
        subtitle: Text(
          '${source.language.toUpperCase()} · ${source.extensionPackage}',
        ),
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            IconButton(
              tooltip: t.sort_by,
              onPressed:
                  index == 0 ? null : () => unawaited(_moveSource(source, -1)),
              icon: const Icon(Icons.keyboard_arrow_up),
            ),
            IconButton(
              tooltip: t.sort_by,
              onPressed: index == manager.sources.length - 1
                  ? null
                  : () => unawaited(_moveSource(source, 1)),
              icon: const Icon(Icons.keyboard_arrow_down),
            ),
            IconButton(
              tooltip: t.mihon_source_preferences,
              onPressed: () => _openPreferences(source),
              icon: const Icon(Icons.tune),
            ),
            IconButton(
              tooltip: t.mihon_source_clear_data,
              onPressed: () => unawaited(_clearSourceData(source)),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
            IconButton(
              tooltip: t.sort_by,
              onPressed: () => unawaited(
                manager.updateSourceSettings(
                  source,
                  pinned: !source.pinned,
                ),
              ),
              icon: Icon(
                source.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MihonPreferencesDialog extends StatefulWidget {
  const _MihonPreferencesDialog({
    required this.manager,
    required this.source,
  });

  final MihonManager manager;
  final MangaOnlineSourceRow source;

  @override
  State<_MihonPreferencesDialog> createState() =>
      _MihonPreferencesDialogState();
}

class _MihonPreferencesDialogState extends State<_MihonPreferencesDialog> {
  List<MihonPreference>? _preferences;
  Object? _error;
  String? _savingKey;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<MihonPreference> preferences =
          await widget.manager.getPreferences(widget.source);
      if (mounted) setState(() => _preferences = preferences);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _save(
    MihonPreference original,
    Object? value,
  ) async {
    final MihonPreference changed = MihonPreference(
      key: original.key,
      kind: original.kind,
      title: original.title,
      summary: original.summary,
      value: value,
      entries: original.entries,
      entryValues: original.entryValues,
    );
    setState(() => _savingKey = original.key);
    try {
      final List<MihonPreference> preferences =
          await widget.manager.setPreference(widget.source, changed);
      if (mounted) setState(() => _preferences = preferences);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _savingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<MihonPreference>? preferences = _preferences;
    return AlertDialog(
      title: Text('${widget.source.name} · ${t.mihon_source_preferences}'),
      content: SizedBox(
        width: 480,
        child: _error != null
            ? Text('$_error')
            : preferences == null
                ? Center(child: adaptiveIndicator(context: context))
                : preferences.isEmpty
                    ? Text(t.mihon_source_no_results)
                    : ListView(
                        shrinkWrap: true,
                        children: <Widget>[
                          for (final MihonPreference preference in preferences)
                            _buildPreference(preference),
                        ],
                      ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.dialog_close),
        ),
      ],
    );
  }

  Widget _buildPreference(MihonPreference preference) {
    final bool busy = _savingKey == preference.key;
    return switch (preference.kind) {
      MihonPreferenceKind.checkBox ||
      MihonPreferenceKind.switchControl =>
        SwitchListTile.adaptive(
          title: Text(preference.title),
          subtitle:
              preference.summary.isEmpty ? null : Text(preference.summary),
          value: preference.value == true,
          onChanged:
              busy ? null : (bool value) => unawaited(_save(preference, value)),
        ),
      MihonPreferenceKind.text => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: TextFormField(
            key: ValueKey<String>(
              '${preference.key}:${preference.value}',
            ),
            initialValue: preference.value?.toString() ?? '',
            enabled: !busy,
            decoration: InputDecoration(
              labelText: preference.title,
              helperText:
                  preference.summary.isEmpty ? null : preference.summary,
            ),
            onFieldSubmitted: (String value) =>
                unawaited(_save(preference, value)),
          ),
        ),
      MihonPreferenceKind.list => DropdownButtonFormField<int>(
          value: (preference.value as int? ?? 0)
              .clamp(0, preference.entries.length - 1),
          decoration: InputDecoration(
            labelText: preference.title,
            helperText: preference.summary.isEmpty ? null : preference.summary,
          ),
          items: <DropdownMenuItem<int>>[
            for (int index = 0; index < preference.entries.length; index++)
              DropdownMenuItem<int>(
                value: index,
                child: Text(preference.entries[index]),
              ),
          ],
          onChanged: busy
              ? null
              : (int? value) => unawaited(_save(preference, value ?? 0)),
        ),
      MihonPreferenceKind.multiSelect => ExpansionTile(
          title: Text(preference.title),
          subtitle:
              preference.summary.isEmpty ? null : Text(preference.summary),
          children: <Widget>[
            for (int index = 0; index < preference.entries.length; index++)
              _MihonMultiSelectRow(
                label: preference.entries[index],
                selected:
                    (preference.value as List<Object?>? ?? const <Object?>[])
                        .map((Object? value) => value.toString())
                        .contains(preference.entryValues[index]),
                onChanged: busy
                    ? null
                    : (bool? selected) {
                        final Set<String> values =
                            (preference.value as List<Object?>? ??
                                    const <Object?>[])
                                .map((Object? value) => value.toString())
                                .toSet();
                        if (selected == true) {
                          values.add(preference.entryValues[index]);
                        } else {
                          values.remove(preference.entryValues[index]);
                        }
                        unawaited(_save(preference, values.toList()));
                      },
              ),
          ],
        ),
      MihonPreferenceKind.unsupported => HibikiListItem(
          leading: const Icon(Icons.warning_amber_outlined),
          title: Text(preference.title),
          subtitle: Text(t.mihon_extension_incompatible),
        ),
    };
  }
}

/// 多选偏好的一行。
///
/// 框架的 `CheckboxListTile` 是被 MD3 守卫禁用的本地 chrome；共享的
/// [HibikiListItem] 没有内建复选语义，所以这里把「点整行 = 切换」的行为显式接上，
/// 与 `CheckboxListTile` 的交互等价（整行可点，禁用态整行不可点）。
class _MihonMultiSelectRow extends StatelessWidget {
  const _MihonMultiSelectRow({
    required this.label,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final ValueChanged<bool?>? changed = onChanged;
    return HibikiListItem(
      title: Text(label),
      leading: Checkbox(value: selected, onChanged: changed),
      onTap: changed == null ? null : () => changed(!selected),
    );
  }
}
