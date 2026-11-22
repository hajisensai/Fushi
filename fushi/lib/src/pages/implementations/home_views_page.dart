/// 首页视图的管理页与编辑页（设置 › 导航 › 首页 ›「管理视图」，以及首页头像菜单的
/// 「新建视图… / 编辑视图…」）。模型与匹配见 `models/home_view.dart`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart' show BookTagRow;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_view.dart';
import 'package:fushi/src/models/home_view_lookup.dart';
import 'package:fushi/src/settings/glass_settings_renderer.dart'
    show GlassSettingsRenderer;
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute, adaptiveSegmentedButton;
import 'package:fushi/src/utils/components/content_language_picker.dart'
    show contentLanguageLabelOf;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show bottomSafeInsetOf;
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 视图的显示名（用户起的名字优先，否则按筛选条件：语言显示名 / 未设语言 / `#标签`）。
String homeViewNameOf(HomeView view, Map<int, String> tagNames) =>
    homeViewDisplayName(
      view,
      languageLabel: contentLanguageLabelOf,
      noLanguageLabel: t.home_view_no_language,
      tagName: (int id) => tagNames[id],
      everythingLabel: t.home_view_everything,
    );

/// 打开「管理视图」页。
Future<void> openHomeViewsPage(BuildContext context) =>
    Navigator.of(context).push<void>(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => const HomeViewsPage(),
      ),
    );

/// 打开视图编辑页；保存返回编辑后的视图，返回 / 取消为 null。[initial] 为 null = 新建。
Future<HomeView?> openHomeViewEditor(
  BuildContext context, {
  HomeView? initial,
}) => Navigator.of(context).push<HomeView>(
  adaptivePageRoute<HomeView>(
    context: context,
    builder: (_) => HomeViewEditorPage(initial: initial),
  ),
);

/// 首页菜单「新建视图…」：编辑、保存，并把首页切到它。
Future<void> createHomeViewAndActivate(
  BuildContext context,
  AppModel appModel,
) async {
  final HomeView? view = await openHomeViewEditor(context);
  if (view == null) return;
  await appModel.setHomeViews(<HomeView>[...appModel.homeViews, view]);
  await appModel.setHomeViewActiveId(view.id);
}

/// 「管理视图」：选本配置首页默认显示哪个视图，新建 / 编辑 / 删除视图。
class HomeViewsPage extends ConsumerStatefulWidget {
  const HomeViewsPage({super.key});

  @override
  ConsumerState<HomeViewsPage> createState() => _HomeViewsPageState();
}

class _HomeViewsPageState extends ConsumerState<HomeViewsPage> {
  Map<int, String> _tagNames = const <int, String>{};

  /// 增删视图时换一代 key，入场动效重播。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadTags());
  }

  Future<void> _loadTags() async {
    final List<BookTagRow> tags = await ref
        .read(appProvider)
        .database
        .getAllTags();
    if (!mounted) return;
    setState(
      () => _tagNames = <int, String>{
        for (final BookTagRow tag in tags) tag.id: tag.name,
      },
    );
  }

  Future<void> _create(AppModel appModel) async {
    final HomeView? view = await openHomeViewEditor(context);
    if (view == null || !mounted) return;
    await appModel.setHomeViews(<HomeView>[...appModel.homeViews, view]);
    if (mounted) setState(() => _generation++);
  }

  Future<void> _edit(AppModel appModel, HomeView view) async {
    final HomeView? edited = await openHomeViewEditor(context, initial: view);
    if (edited == null || !mounted) return;
    await appModel.setHomeViews(<HomeView>[
      for (final HomeView v in appModel.homeViews) v.id == view.id ? edited : v,
    ]);
  }

  Future<void> _delete(AppModel appModel, HomeView view) async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.home_view_delete_confirm(name: homeViewNameOf(view, _tagNames)),
      icon: FushiIcons.delete,
      confirmLabel: t.home_view_delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    if (appModel.homeViewActiveId == view.id) {
      await appModel.setHomeViewActiveId(kHomeViewEverythingId);
    }
    await appModel.setHomeViews(<HomeView>[
      for (final HomeView v in appModel.homeViews)
        if (v.id != view.id) v,
    ]);
    if (mounted) setState(() => _generation++);
  }

  Widget _check(bool selected) => selected
      ? FushiIcon(
          FushiIcons.check,
          color: Theme.of(context).colorScheme.primary,
        )
      : const SizedBox.shrink();

  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    final List<HomeView> views = appModel.homeViews;
    final String activeId =
        resolveActiveHomeView(
          enabled: true,
          views: views,
          activeId: appModel.homeViewActiveId,
        )?.id ??
        kHomeViewEverythingId;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final List<Widget> sections = <Widget>[
      AdaptiveSettingsSection(
        title: t.home_views_default_section,
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('home-views-default/everything'),
            title: t.home_view_everything,
            icon: FushiIcons.home,
            showIcon: true,
            trailing: _check(activeId == kHomeViewEverythingId),
            onTap: () =>
                unawaited(appModel.setHomeViewActiveId(kHomeViewEverythingId)),
          ),
          for (final HomeView v in views)
            AdaptiveSettingsRow(
              key: ValueKey<String>('home-views-default/${v.id}'),
              title: homeViewNameOf(v, _tagNames),
              icon: FushiIcons.filterList,
              showIcon: true,
              trailing: _check(activeId == v.id),
              onTap: () => unawaited(appModel.setHomeViewActiveId(v.id)),
            ),
        ],
      ),
      AdaptiveSettingsSection(
        title: t.home_views_saved_section,
        children: <Widget>[
          for (final HomeView v in views)
            AdaptiveSettingsRow(
              key: ValueKey<String>('home-views-edit/${v.id}'),
              title: homeViewNameOf(v, _tagNames),
              subtitle: v.name.trim().isEmpty
                  ? null
                  : homeViewNameOf(v.copyWith(name: ''), _tagNames),
              icon: FushiIcons.edit,
              showIcon: true,
              onTap: () => unawaited(_edit(appModel, v)),
              trailing: FushiIconButton(
                key: ValueKey<String>('home-views-delete/${v.id}'),
                icon: FushiIcons.delete,
                tooltip: t.home_view_delete,
                onTap: () => unawaited(_delete(appModel, v)),
              ),
            ),
          AdaptiveSettingsRow(
            key: const ValueKey<String>('home-views-add'),
            title: t.home_view_editor_new_title,
            icon: FushiIcons.add,
            showIcon: true,
            onTap: () => unawaited(_create(appModel)),
          ),
        ],
      ),
    ];
    return SettingsKitScaffold(
      title: t.settings_home_views_manage,
      leadingIcon: FushiIcons.filterList,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => FushiEntranceScope(
            replayKey: _generation,
            child: ListView(
              controller: controller,
              padding: EdgeInsets.fromLTRB(
                inset,
                tokens.spacing.gap + MediaQuery.paddingOf(context).top,
                inset,
                tokens.spacing.page + bottomSafeInsetOf(context),
              ),
              children: <Widget>[
                for (int i = 0; i < sections.length; i++)
                  FushiStaggeredEntrance(
                    key: ValueKey<String>(
                      'home-views-entrance-$_generation-$i',
                    ),
                    index: i,
                    child: sections[i],
                  ),
              ],
            ),
          ),
    );
  }
}

/// 视图编辑页：名字、语言（库里出现过的 + 未设语言）、标签（标签池）与标签匹配方式。
class HomeViewEditorPage extends ConsumerStatefulWidget {
  const HomeViewEditorPage({super.key, this.initial});

  /// null = 新建。
  final HomeView? initial;

  @override
  ConsumerState<HomeViewEditorPage> createState() => _HomeViewEditorPageState();
}

class _HomeViewEditorPageState extends ConsumerState<HomeViewEditorPage> {
  late HomeView _view = widget.initial ?? HomeView(id: newHomeViewId());
  List<String> _libraryLanguages = const <String>[];
  bool _libraryHasNoLanguage = false;
  List<BookTagRow> _tags = const <BookTagRow>[];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final AppModel appModel = ref.read(appProvider);
    final ({List<String> languages, bool hasNoLanguage}) options =
        await loadHomeViewLanguageOptions(appModel.database);
    final List<BookTagRow> tags = await appModel.database.getAllTags();
    if (!mounted) return;
    setState(() {
      _libraryLanguages = options.languages;
      _libraryHasNoLanguage = options.hasNoLanguage;
      _tags = tags;
      _loaded = true;
    });
  }

  Map<int, String> get _tagNames => <int, String>{
    for (final BookTagRow tag in _tags) tag.id: tag.name,
  };

  /// 可选语言 = 库里出现过的 ∪ 本视图已选的（库里已没有的也留着，能取消）。
  List<String> get _languageOptions =>
      <String>{..._libraryLanguages, ..._view.languages}.toList()..sort();

  Future<void> _rename() async {
    final String? name = await showFushiTextInputDialog(
      context: context,
      title: t.home_view_rename,
      message: t.home_view_editor_name_hint,
      initialValue: _view.name,
      hintText: homeViewNameOf(_view.copyWith(name: ''), _tagNames),
      confirmLabel: t.home_view_save,
      icon: FushiIcons.edit,
      allowEmpty: true,
    );
    if (name == null || !mounted) return;
    setState(() => _view = _view.copyWith(name: name));
  }

  void _save() {
    if (_view.isEverything) {
      FushiToast.show(msg: t.home_view_editor_empty_filter);
      return;
    }
    // 已删除的标签不留在视图里（否则「全部标签」永远凑不齐）。
    final Set<int> existing = _tags.map((BookTagRow t) => t.id).toSet();
    final HomeView cleaned = _loaded
        ? _view.copyWith(tagIds: _view.tagIds.where(existing.contains).toSet())
        : _view;
    if (cleaned.isEverything) {
      FushiToast.show(msg: t.home_view_editor_empty_filter);
      return;
    }
    Navigator.of(context).pop(cleaned);
  }

  Widget _chips(List<Widget> chips) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    ),
  );

  Widget _languageSection() {
    final List<String> options = _languageOptions;
    final bool showNoLanguage =
        _libraryHasNoLanguage || _view.includeNoLanguage || options.isEmpty;
    return AdaptiveSettingsSection(
      title: t.home_view_editor_languages,
      children: <Widget>[
        _chips(<Widget>[
          for (final String lang in options)
            FushiFilterChip(
              key: ValueKey<String>('home-view-lang/$lang'),
              label: Text(contentLanguageLabelOf(lang)),
              selected: _view.languages.contains(lang),
              onSelected: (bool on) => setState(
                () => _view = _view.copyWith(
                  languages: on
                      ? <String>{..._view.languages, lang}
                      : (<String>{..._view.languages}..remove(lang)),
                ),
              ),
            ),
          if (showNoLanguage)
            FushiFilterChip(
              key: const ValueKey<String>('home-view-lang/none'),
              label: Text(t.home_view_no_language),
              selected: _view.includeNoLanguage,
              onSelected: (bool on) =>
                  setState(() => _view = _view.copyWith(includeNoLanguage: on)),
            ),
        ]),
      ],
    );
  }

  Widget _tagSection() {
    final TextStyle? muted = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: fushiNeutralSecondaryForeground(context),
    );
    return AdaptiveSettingsSection(
      title: t.home_view_editor_tags,
      children: <Widget>[
        if (_tags.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _loaded ? t.home_view_editor_no_tags : '',
              style: muted,
            ),
          )
        else
          _chips(<Widget>[
            for (final BookTagRow tag in _tags)
              FushiFilterChip(
                key: ValueKey<String>('home-view-tag/${tag.id}'),
                label: Text('#${tag.name}'),
                selected: _view.tagIds.contains(tag.id),
                onSelected: (bool on) => setState(
                  () => _view = _view.copyWith(
                    tagIds: on
                        ? <int>{..._view.tagIds, tag.id}
                        : (<int>{..._view.tagIds}..remove(tag.id)),
                  ),
                ),
              ),
          ]),
        if (_tags.isNotEmpty)
          AdaptiveSettingsRow(
            key: const ValueKey<String>('home-view-match'),
            title: t.home_view_editor_match,
            icon: FushiIcons.filter,
            showIcon: true,
            trailing: adaptiveSegmentedButton<bool>(
              context: context,
              segments: <ButtonSegment<bool>>[
                ButtonSegment<bool>(
                  value: false,
                  label: Text(t.home_view_editor_match_any),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text(t.home_view_editor_match_all),
                ),
              ],
              selected: <bool>{_view.matchAllTags},
              onSelectionChanged: (Set<bool> s) =>
                  setState(() => _view = _view.copyWith(matchAllTags: s.first)),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double inset = isGlassDesign(context)
        ? GlassSettingsRenderer.detailHorizontalInset(context)
        : tokens.spacing.page;
    final List<Widget> sections = <Widget>[
      AdaptiveSettingsSection(
        title: t.home_view_editor_name,
        children: <Widget>[
          AdaptiveSettingsRow(
            key: const ValueKey<String>('home-view-name'),
            title: homeViewNameOf(_view, _tagNames),
            subtitle: t.home_view_editor_name_hint,
            icon: FushiIcons.edit,
            showIcon: true,
            onTap: () => unawaited(_rename()),
          ),
        ],
      ),
      _languageSection(),
      _tagSection(),
      Padding(
        padding: EdgeInsets.only(top: tokens.spacing.gap),
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FushiFilledButton(
            key: const ValueKey<String>('home-view-save-button'),
            onPressed: _save,
            child: Text(t.home_view_save),
          ),
        ),
      ),
    ];
    return SettingsKitScaffold(
      title: widget.initial == null
          ? t.home_view_editor_new_title
          : t.home_view_editor_edit_title,
      leadingIcon: FushiIcons.filterList,
      bodyConsumesTopPadding: true,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('home-view-save'),
          icon: FushiIcons.check,
          tooltip: t.home_view_save,
          onTap: _save,
        ),
      ],
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => FushiEntranceScope(
            child: ListView(
              controller: controller,
              padding: EdgeInsets.fromLTRB(
                inset,
                tokens.spacing.gap + MediaQuery.paddingOf(context).top,
                inset,
                tokens.spacing.page + bottomSafeInsetOf(context),
              ),
              children: <Widget>[
                for (int i = 0; i < sections.length; i++)
                  FushiStaggeredEntrance(
                    key: ValueKey<String>('home-view-editor-entrance-$i'),
                    index: i,
                    child: sections[i],
                  ),
              ],
            ),
          ),
    );
  }
}
