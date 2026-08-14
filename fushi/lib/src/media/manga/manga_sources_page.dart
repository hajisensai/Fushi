import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_package_store.dart';
import 'package:fushi/src/media/manga/aidoku/aidoku_runtime.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/online/mokuro_moe_source_row.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/media_sources_view.dart';
import 'package:fushi/utils.dart';

/// 漫画库「来源」视图：本域**所有**来源的唯一管理处。
///
/// 四节，自上而下：
/// 1. 本地漫画扫描根（与书 / 视频共用的 [MediaSourcesView]）；
/// 2. Aidoku 扩展（macOS 上导入 / 移除 `.aix`）；
/// 3. 漫画扩展（Mihon 扩展仓库 + 安装 / 启停 / 卸载）——用户口径：「漫画扩展
///    不就是来源吗，来源设置里面加上就行了」，因此**不另开顶层 tab**；
/// 4. 在线漫画源：内置的 mokuro.moe **与**扩展提供的源并列（启停 / 排序 / 偏好 /
///    清数据 / 置顶）。
///
/// 🔴 mokuro.moe 归第 4 节，不归第 1 节（BUG-1431）：它是个网站，不是本地扫描根。
/// 之前它和「Hibiki 互联」一起挂在「本地扫描根」下，用户口径「mokuro 不应该单独
/// 显示，应该和漫画扩展同一层级」。挪进「漫画源」后它与扩展源同构——同一节、同一
/// 种开关语义（关掉 = 不在「浏览」里出现）。
///
/// 🔴 本页的滚动容器必须是 [CustomScrollView]（BUG-1441）：第 3 节要渲染整个扩展
/// 仓库（keiyoushi 有 1900+ 条），只有 sliver 才能懒建。换回 `ListView` +
/// 内嵌 `Column` 会立刻把「语言下拉一展开就卡死」带回来。
///
/// 平台差异只在**内容**：Aidoku 目前仅在 macOS 显示导入入口；iOS / Linux 没有
/// Mihon 扩展宿主，对应两节渲染不可用提示，视图本身与其它平台同构、同位。
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
  AidokuPackageStore? _aidokuStore;
  List<AidokuInstalledPackage>? _aidokuPackages;
  Object? _aidokuError;
  bool _aidokuBusy = false;

  @override
  void initState() {
    super.initState();
    if (DesktopAidokuRuntime.isSupported) {
      unawaited(_initializeAidokuStore());
    }
  }

  Future<void> _initializeAidokuStore() async {
    try {
      final AidokuPackageStore store = await AidokuPackageStore.open();
      final List<AidokuInstalledPackage> packages = await store.listInstalled();
      if (!mounted) return;
      setState(() {
        _aidokuStore = store;
        _aidokuPackages = packages;
        _aidokuError = null;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _aidokuError = error);
    }
  }

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

  /// 单卷 / 单文件漫画导入：与旧漫画库页头按钮同一个对话框（目录 / `.mokuro` /
  /// `.cbz` / 图片包 + OCR 向导）。落库成功后失效书架 provider 刷新漫画库。
  Future<void> _importManga() async {
    final FushiDatabase db = ref.read(appProvider).database;
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => MangaImportDialog(db: db),
    );
    if (imported == true && mounted) {
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
      ref.invalidate(srtBooksProvider);
    }
  }

  Future<void> _importAidoku() async {
    if (!DesktopAidokuRuntime.isSupported || _aidokuBusy) return;
    final bool acceptedRisk = await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog.adaptive(
            title: Text(t.aidoku_extension_import),
            content: Text(t.aidoku_extension_warning),
            actions: <Widget>[
              adaptiveDialogAction(
                context: dialogContext,
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(t.dialog_cancel),
              ),
              adaptiveDialogAction(
                context: dialogContext,
                isDefaultAction: true,
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(t.dialog_select),
              ),
            ],
          ),
        ) ??
        false;
    if (!acceptedRisk || !mounted) return;

    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['aix'],
      allowMultiple: false,
      withData: false,
    );
    final String? path = picked?.files.single.path;
    if (!mounted || path == null) return;

    setState(() {
      _aidokuBusy = true;
      _aidokuError = null;
    });
    try {
      final DesktopAidokuRuntime runtime = DesktopAidokuRuntime();
      final AidokuPackageInspection inspection = await runtime.inspect(path);
      if (!mounted) return;
      if (inspection.requiresWebView) {
        throw AidokuRuntimeException(
          'WEBVIEW_REQUIRED',
          t.aidoku_webview_unsupported,
        );
      }
      final Map<String, Object?> info = inspection.sourceInfo;
      final bool confirmed = await showAppDialog<bool>(
            context: context,
            builder: (BuildContext dialogContext) => AlertDialog.adaptive(
              title: Text(t.aidoku_extension_confirm_title),
              content: Text(
                '${info['name']}\n${info['id']}\n'
                '${t.aidoku_extension_version}: ${info['version']}',
              ),
              actions: <Widget>[
                adaptiveDialogAction(
                  context: dialogContext,
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text(t.dialog_cancel),
                ),
                adaptiveDialogAction(
                  context: dialogContext,
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(t.dialog_import),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted) return;
      final AidokuPackageStore store =
          _aidokuStore ?? await AidokuPackageStore.open();
      _aidokuStore = store;
      final AidokuInstalledPackage installed =
          await store.install(File(path), inspection);
      final List<AidokuInstalledPackage> packages = await store.listInstalled();
      if (!mounted) return;
      setState(() => _aidokuPackages = packages);
      FushiToast.show(
        msg: '${t.aidoku_extension_imported}: ${installed.name}',
        severity: ToastSeverity.success,
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _aidokuError = error);
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _aidokuBusy = false);
    }
  }

  Future<void> _removeAidoku(AidokuInstalledPackage package) async {
    final bool confirmed = await showAppDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog.adaptive(
            title: Text(t.aidoku_extension_remove),
            content: Text(package.name),
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
                child: Text(t.dialog_delete),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      await _aidokuStore!.remove(package);
      final List<AidokuInstalledPackage> packages =
          await _aidokuStore!.listInstalled();
      if (mounted) setState(() => _aidokuPackages = packages);
    } on Object catch (error) {
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    }
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
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
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

  /// 页头。与 `MediaSourcesPage` 同一范式：库页视图导航条存在时它就是页头主位，
  /// **不再另渲染一个页面大标题**——导航条自己已经标明了当前在哪个视图，标题只是
  /// 重复占一行。仅在没有导航条（独立 push 进来）时才回退到文字标题。
  Widget _buildHeader() {
    final List<Widget> actions = <Widget>[
      FushiIconButton(
        tooltip: t.media_source_add,
        label: t.media_source_add,
        icon: Icons.create_new_folder_outlined,
        onTap: () => _localSourcesKey.currentState?.addSource(),
      ),
    ];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(
        title: navigation,
        actions: actions,
      );
    }
    return FushiPageHeader(
      title: t.media_source_manage_title,
      actions: actions,
    );
  }

  /// 扩展宿主不可用时统一的占位（iOS / Linux）。结构不变，只是这一节没内容。
  Widget _unavailableNote() => Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          t.mihon_runtime_unavailable,
          textAlign: TextAlign.center,
        ),
      );

  Widget _buildAidokuSection() {
    if (!DesktopAidokuRuntime.isSupported) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          t.aidoku_runtime_unavailable,
          textAlign: TextAlign.center,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FushiIconButton(
              key: const ValueKey<String>('aidoku_import_aix'),
              tooltip: t.aidoku_extension_import,
              label: t.aidoku_extension_import,
              icon: Icons.file_open_outlined,
              onTap: _aidokuBusy ? null : _importAidoku,
            ),
          ],
        ),
        if (_aidokuBusy || (_aidokuPackages == null && _aidokuError == null))
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        if (_aidokuError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '$_aidokuError',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          )
        else if (_aidokuPackages?.isEmpty == true)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(t.aidoku_extension_empty),
          ),
        for (final AidokuInstalledPackage package
            in _aidokuPackages ?? const <AidokuInstalledPackage>[])
          FushiCard(
            padding: EdgeInsets.zero,
            child: FushiListItem(
              leading: const Icon(Icons.extension_outlined),
              title: Text(package.name),
              subtitle: Text(
                '${package.languages.join(', ').toUpperCase()} · '
                '${t.aidoku_extension_version} ${package.version}\n'
                '${package.id}',
              ),
              trailing: IconButton(
                tooltip: t.aidoku_extension_remove,
                onPressed: () => unawaited(_removeAidoku(package)),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final MihonManager? manager = _manager;
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!isCupertinoPlatform(context)) _buildHeader(),
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
                            // 快速导入区：单卷 / 单文件入口（与书 / 视频「导入」
                            // 视图同构同位；对话框内含文件 / 文件夹 / OCR 向导）。
                            QuickImportSection(
                              actions: <QuickImportAction>[
                                QuickImportAction(
                                  icon: Icons.auto_stories_outlined,
                                  label: t.manga_import_action,
                                  onTap: _importManga,
                                ),
                                if (DesktopAidokuRuntime.isSupported)
                                  QuickImportAction(
                                    icon: Icons.extension_outlined,
                                    label: t.aidoku_extension_import,
                                    onTap: _importAidoku,
                                    enabled: !_aidokuBusy,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 28),
                            _sectionTitle(t.media_source_local_roots),
                            const SizedBox(height: 8),
                            MediaSourcesView(
                              key: _localSourcesKey,
                              mediaKind: 'manga',
                            ),
                            const SizedBox(height: 28),
                            _sectionTitle(t.aidoku_extensions_title),
                            const SizedBox(height: 8),
                            _buildAidokuSection(),
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
    return FushiCard(
      padding: EdgeInsets.zero,
      child: FushiListItem(
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
      MihonPreferenceKind.unsupported => FushiListItem(
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
/// [FushiListItem] 没有内建复选语义，所以这里把「点整行 = 切换」的行为显式接上，
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
    return FushiListItem(
      title: Text(label),
      leading: Checkbox(value: selected, onChanged: changed),
      onTap: changed == null ? null : () => changed(!selected),
    );
  }
}
