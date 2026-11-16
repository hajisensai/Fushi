import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart'
    show
        HardwareKeyboard,
        KeyDownEvent,
        KeyEvent,
        KeyRepeatEvent,
        LogicalKeyboardKey,
        PlatformException;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:path/path.dart' as path;
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/media/types/dictionary_media_type.dart';
import 'package:fushi/src/pages/base_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_delete_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_dialog_import_page.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/models/dictionary_download_controller.dart';
import 'package:fushi/src/models/dictionary_repository.dart'
    show DictionaryRepository, RemoteDictionary, RemoteDictionaryHostSource;
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/sync/remote_dictionary_catalog_service.dart'
    show RemoteDictionaryCatalogService, RemoteDictionaryHostReachability;
import 'package:fushi/src/sync/dictionary_transfer_service.dart';
import 'package:fushi/src/sync/sync_repository.dart' show SyncRepository;
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show showFushiConfirmDialog;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/models/dictionary_download_resume.dart';
import 'package:fushi/src/models/dictionary_import_manager.dart';
import 'package:fushi/src/dictionary/recommended_dictionary_installer.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show ActivityRelativeTime, ActivityRelativeUnit, activityRelativeTime;
import 'package:fushi/src/pages/implementations/dictionary_manager_panels.dart';
import 'package:fushi/src/pages/implementations/name_input_dialog.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_dropdown.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_reorderable_column.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';

// ── BUG-1493：下载/导入两阶段的可归因进度 ──────────────────────────────
//
// 顶层函数而非 State 的私有方法：这两条是「用户看到的是不是一个能归因的进度」的
// 全部逻辑，必须能被单测直接钉住（State 是私有类，测试够不着）。

/// 下载阶段的文案：**说清在下载、下了多少**。
///
/// 旧实现整个下载期只有一句静态「正在更新 X…」，配上一条几乎贴着最左端不动的进度
/// 条——用户完全看不出是在下载、下到哪了、还是已经挂死。词典包 30~55MB 且源在
/// GitHub / HuggingFace，慢是常态，慢而无归因才是缺陷。
///
/// 服务器不给 `Content-Length` 时 `total <= 0`，退回不带分母的「正在下载 X…」，
/// **不显示假的分母**。
@visibleForTesting
String dictionaryDownloadStageMessage({
  required String name,
  required int received,
  required int total,
}) {
  if (total <= 0) return t.dict_downloading(name: name);
  return t.dict_downloading_size(
    name: name,
    done: FushiByteFormat.bytes(received),
    total: FushiByteFormat.bytes(total),
  );
}

/// 从下载阶段切进导入阶段。
///
/// **必须把 [downloadProgress] 归零**：下载结束时它是 1.0，而导入阶段没有任何一处
/// 会再写它（native 导入是一次不可分割的 FFI 调用，C++ 侧无进度回调），于是进度条
/// 会定格在满格一动不动——这正是「看起来卡死」的直接来源。归零后
/// `LinearProgressIndicator(value: progress > 0 ? progress : null)` 退化成不定态
/// 动画，如实表达「正在处理、无法估算剩余」。
///
/// BUG-1499：同一个「不可分割的 FFI 调用、C++ 侧无回调」也决定了导入**中途取消不
/// 可达**，所以进了这一阶段必须把取消按钮禁掉——传 [job] 让阶段一并切过去。
@visibleForTesting
void enterDictionaryImportStage({
  required String name,
  required ValueNotifier<String> progressNotifier,
  required ValueNotifier<double> downloadProgress,
  DictionaryDownloadJob? job,
}) {
  job?.markImportPhase();
  downloadProgress.value = 0;
  progressNotifier.value = t.import_name(name: name);
}

/// Page used for managing installed dictionaries.
/// 推荐词典下载弹窗的「可勾选下标域」：catalog 全体减去已安装项。
///
/// 全选 / 反选 / 分类三态一律以此为域，与默认勾选同判据（
/// `defaultSelectionForLearningLang` 的结果也要 `.difference(installedIndices)`）：
/// 已装的词典再下一遍只会走一趟无谓的下载 + 导入，把它们算进「全选」等于把
/// 47 条目录里最贵的那部分默认塞给用户。
@visibleForTesting
Set<int> selectableDictionaryIndices({
  required int catalogLength,
  required Set<int> installedIndices,
}) {
  return <int>{
    for (int i = 0; i < catalogLength; i++)
      if (!installedIndices.contains(i)) i,
  };
}

/// 分类头三态勾选框的值：全选 true / 全不选 false / 部分 null。
///
/// [categoryIndices] 只应传本类的**可勾选**下标；本类全是已安装项时传空集，
/// 调用方据此把勾选框禁用（无可选项时 true/false 都是谎话）。
@visibleForTesting
bool? dictionaryCategoryCheckState({
  required Set<int> categoryIndices,
  required Set<int> checked,
}) {
  if (categoryIndices.isEmpty) return false;
  final int hit = categoryIndices.where(checked.contains).length;
  if (hit == 0) return false;
  if (hit == categoryIndices.length) return true;
  return null;
}

/// 推荐词典目录的勾选列表：顶部「已选 N · 全选 · 反选」+ 按分类折叠的三态勾选。
///
/// 从 `_showDownloadSelectionDialog` 的内联闭包里抽出来，是为了让「全选只作用于
/// 可勾选域」「分类三态」这些接线能被真的测到——判据的纯函数好测，但按钮接错域
/// （比如把已安装项也算进全选）编译期看不出来，只有 widget 用例拦得住。
@visibleForTesting
class DictionaryCatalogSelectionList extends StatelessWidget {
  const DictionaryCatalogSelectionList({
    required this.workingCatalog,
    required this.byCategory,
    required this.recIndex,
    required this.installedIndices,
    required this.checked,
    required this.expandedCategories,
    required this.onCheckedChanged,
    required this.onExpansionChanged,
    super.key,
  });

  final List<RecommendedDictionary> workingCatalog;
  final Map<DictionaryCategory, List<RecommendedDictionary>> byCategory;
  final Map<RecommendedDictionary, int> recIndex;
  final Set<int> installedIndices;
  final Set<int> checked;
  final Set<DictionaryCategory> expandedCategories;
  final ValueChanged<Set<int>> onCheckedChanged;
  final void Function(DictionaryCategory cat, bool expanded) onExpansionChanged;

  String _categoryLabel(DictionaryCategory cat) => switch (cat) {
    DictionaryCategory.jaEn => t.dict_category_ja_en,
    DictionaryCategory.jaJa => t.dict_category_ja_ja,
    DictionaryCategory.jaOther => t.dict_category_ja_other,
    DictionaryCategory.grammar => t.dict_category_grammar,
    DictionaryCategory.kanji => t.dict_category_kanji,
    DictionaryCategory.frequency => t.dict_category_frequency,
    DictionaryCategory.names => t.dict_category_names,
    DictionaryCategory.supplementary => t.dict_category_supplementary,
    DictionaryCategory.bilingual => t.dict_category_bilingual,
    DictionaryCategory.monolingual => t.dict_category_monolingual,
  };

  void _toggleOne(int idx, bool value) {
    final Set<int> next = Set<int>.of(checked);
    if (value) {
      next.add(idx);
    } else {
      next.remove(idx);
    }
    onCheckedChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextTheme textTheme = theme.textTheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 47 条目录 + 分类折叠下，逐条点是唯一的入口太贵：全选 / 反选一律只作用于
    // **可勾选域**（已装的不参与，见 [selectableDictionaryIndices]）。
    final Set<int> selectable = selectableDictionaryIndices(
      catalogLength: workingCatalog.length,
      installedIndices: installedIndices,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              t.batch_selected_count(n: checked.length),
              style: textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            FushiTextButton(
              key: const ValueKey<String>('dict-download-select-all'),
              onPressed: selectable.isEmpty
                  ? null
                  : () => onCheckedChanged(Set<int>.of(selectable)),
              child: Text(t.batch_select_all),
            ),
            FushiTextButton(
              key: const ValueKey<String>('dict-download-invert-selection'),
              onPressed: selectable.isEmpty
                  ? null
                  : () => onCheckedChanged(selectable.difference(checked)),
              child: Text(t.batch_invert_selection),
            ),
          ],
        ),
        SizedBox(height: tokens.spacing.gap),
        for (final DictionaryCategory cat in DictionaryCategory.values)
          if (byCategory.containsKey(cat))
            _buildCategoryTile(
              context: context,
              theme: theme,
              textTheme: textTheme,
              tokens: tokens,
              cat: cat,
              items: byCategory[cat]!,
              expanded: expandedCategories.contains(cat),
            ),
      ],
    );
  }

  Widget _buildCategoryTile({
    required BuildContext context,
    required ThemeData theme,
    required TextTheme textTheme,
    required FushiDesignTokens tokens,
    required DictionaryCategory cat,
    required List<RecommendedDictionary> items,
    required bool expanded,
  }) {
    // 本类的可勾选下标（已装的不算），三态框与「本类全选」同域。
    final Set<int> categoryIndices = <int>{
      for (final RecommendedDictionary rec in items)
        if (recIndex[rec] != null && !installedIndices.contains(recIndex[rec]))
          recIndex[rec]!,
    };
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: FushiCard(
        padding: EdgeInsets.zero,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiListItem(
              minHeight: 52,
              leading: FushiCheckbox(
                key: ValueKey<String>(
                  'dict-download-category-check-${cat.name}',
                ),
                tristate: true,
                value: dictionaryCategoryCheckState(
                  categoryIndices: categoryIndices,
                  checked: checked,
                ),
                onChanged: categoryIndices.isEmpty
                    ? null
                    : (bool? value) {
                        final Set<int> next = Set<int>.of(checked);
                        if (value ?? false) {
                          next.addAll(categoryIndices);
                        } else {
                          next.removeAll(categoryIndices);
                        }
                        onCheckedChanged(next);
                      },
              ),
              title: Text(
                _categoryLabel(cat),
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              trailing: FushiIcon(
                expanded ? Icons.expand_less : Icons.expand_more,
                color: tokens.surfaces.onVariant,
              ),
              onTap: () => onExpansionChanged(cat, !expanded),
            ),
            if (expanded)
              for (final RecommendedDictionary rec in items)
                _buildDictCheckbox(
                  theme: theme,
                  textTheme: textTheme,
                  tokens: tokens,
                  rec: rec,
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildDictCheckbox({
    required ThemeData theme,
    required TextTheme textTheme,
    required FushiDesignTokens tokens,
    required RecommendedDictionary rec,
  }) {
    // HBK-AUDIT-110: O(1) lookup from a precomputed map instead of the former
    // per-checkbox catalog.indexOf(rec) linear scan on every rebuild.
    final int idx = recIndex[rec] ?? -1;
    final bool installed = installedIndices.contains(idx);
    final bool selected = checked.contains(idx);
    return FushiListItem(
      key: ValueKey<String>('dict-download-entry-${rec.name}'),
      minHeight: 68,
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal - tokens.spacing.gap / 2,
        vertical: tokens.spacing.gap,
      ),
      selected: selected,
      onTap: () => _toggleOne(idx, !selected),
      leading: FushiCheckbox(
        value: selected,
        onChanged: (bool? value) => _toggleOne(idx, value ?? false),
      ),
      title: Text(
        rec.name,
        style: textTheme.bodyMedium?.copyWith(
          color: installed ? theme.colorScheme.onSurfaceVariant : null,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        installed
            ? '${t.dict_download_installed}  ${rec.sizeEstimate}'
            : '${rec.description}  ${rec.sizeEstimate}',
        style: textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class DictionaryDialogPage extends BasePage {
  /// Create an instance of this page.
  const DictionaryDialogPage({
    super.key,
    this.initialImportPaths = const <String>[],
  });

  /// Dictionary package paths to import as soon as the page is visible. CSS
  /// attachment paths may be included after at least one dictionary package.
  final List<String> initialImportPaths;

  @override
  BasePageState createState() => _DictionaryDialogPageState();
}

class _DictionaryDialogPageState extends BasePageState {
  DictionaryType _selectedType = DictionaryType.term;

  /// 多选态：行首换成复选框，底部钉批量操作栏（启用 / 停用 / 删除）。
  bool _selecting = false;

  /// 多选态下选中的词典（按真名，真名是主键）。只在当前类型内选，切类型清空。
  final Set<String> _selectedNames = <String>{};

  /// 两栏布局（宽屏）右侧详情侧板正在展示的行（[DictionaryManagerRow.key]：本机
  /// 词典是真名，服务器词典带前缀）；null = 概览。
  String? _detailName;

  /// 列表上方的来源筛选（只在有服务器词典时出现）。
  DictionarySourceFilter _sourceFilter = DictionarySourceFilter.all;

  /// host 身份 → 展示名（配对记下的设备名），来源标签 / 筛选 / host 提示用。
  Map<String, String> _hostNames = const <String, String>{};

  /// 「刷新服务器词典」进行中。
  bool _refreshingServer = false;

  /// 「来源」条的数据：每台有目录行的已配对 host（含关掉「用它查词典」的）。
  List<RemoteDictionaryHostSource> _hostSources =
      const <RemoteDictionaryHostSource>[];

  /// 来源卡片上正在单独刷新的 host。
  final Set<String> _refreshingHosts = <String>{};

  /// 「推送到 <服务器>」的候选 host（已配对、开着「用它查词典」）。
  Set<String> _pushHostIds = const <String>{};

  /// 顶栏副标题里的激活配置名；null = 还没读到 / 读不到（不画副标题）。
  String? _profileName;

  /// 每次 setState 自增：窄屏底部 sheet 是另一条路由，页面 setState 重建不到它，
  /// sheet 内容监听这个计数跟着刷新（开关 / 改名 / 排序后 sheet 立刻反映）。
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// 每行一个不取焦点的外层节点：Alt+↑/↓ 挪动后焦点要跟着词典走，而
  /// FushiReorderableColumn 的行元素按下标复用，焦点会留在原下标那一行。
  final Map<String, FocusNode> _rowFocusNodes = <String, FocusNode>{};

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _revision.value++;
  }

  @override
  void dispose() {
    DictionaryRepository.remoteDictionariesRevision.removeListener(
      _onRemoteDictionariesChanged,
    );
    SyncRepository.fushiClientUrlsRevision.removeListener(
      _onRemoteDictionariesChanged,
    );
    RemoteDictionaryCatalogService.catalogRevision.removeListener(
      _onRemoteDictionariesChanged,
    );
    RemoteDictionaryCatalogService.reachabilityRevision.removeListener(
      _onReachabilityChanged,
    );
    _revision.dispose();
    for (final FocusNode node in _rowFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// BUG-1500：判「是否已有下载在跑」的唯一真相源是 app 级 controller，不再是页面
  /// 私有的 bool——页面 bool 挡不住启动时的静默自动更新，两条流程能并发写同一本词典。
  bool get _isDownloading => appModel.dictionaryDownloadController.isBusy;

  @override
  void initState() {
    super.initState();
    // 服务器词典目录刷新 / 配置写入 / 配对列表（设备名、「用它查词典」开关）变化时
    // 跟着重建：服务器行由词典仓库持有，页面不存镜像。
    DictionaryRepository.remoteDictionariesRevision.addListener(
      _onRemoteDictionariesChanged,
    );
    SyncRepository.fushiClientUrlsRevision.addListener(
      _onRemoteDictionariesChanged,
    );
    // 关掉「用它查词典」的 host 不在仓库的服务器行里，它的目录变化只走目录广播。
    RemoteDictionaryCatalogService.catalogRevision.addListener(
      _onRemoteDictionariesChanged,
    );
    RemoteDictionaryCatalogService.reachabilityRevision.addListener(
      _onReachabilityChanged,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadServerSources());
      unawaited(_loadProfileName());
    });
    if (widget is DictionaryDialogPage) {
      final List<String> paths =
          (widget as DictionaryDialogPage).initialImportPaths;
      if (paths.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          debugPrint(
            '[fushi-drop] [dictionary-dialog] initialImportPaths=${paths.length}',
          );
          if (mounted) unawaited(_importDictionaryPaths(paths));
        });
      }
    }
  }

  void _onRemoteDictionariesChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_loadServerSources());
    // 切换配置会重载词典仓库（服务器行随之广播），顶栏的配置名跟着重读。
    unawaited(_loadProfileName());
  }

  void _onReachabilityChanged() {
    if (mounted) setState(() {});
  }

  /// 读配对 host 的展示名与「来源」条数据（页面不存镜像：每次广播都整份重读）。
  Future<void> _loadServerSources() async {
    final Map<String, String> names;
    final List<RemoteDictionaryHostSource> sources;
    final Set<String> pushHosts;
    try {
      names = await appModel.remoteDictionaryHostNames();
      sources = await appModel.remoteDictionaryHostSources();
      pushHosts = await appModel.remoteDictionaryPushHostIds();
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryDialog.serverSources', e, stack);
      return;
    }
    if (!mounted) return;
    setState(() {
      _hostNames = names;
      _hostSources = sources;
      _pushHostIds = pushHosts;
    });
  }

  Future<void> _loadProfileName() async {
    final String? name;
    try {
      name = await appModel.activeProfileName();
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryDialog.profileName', e, stack);
      return;
    }
    if (!mounted || name == _profileName) return;
    setState(() => _profileName = name);
  }

  /// 顶栏副标题「配置 · 名字」：焦点 + Enter 打开现有的配置管理页（切换 / 管理配置都
  /// 在那里），回来后重读名字。
  Future<void> _openProfiles() async {
    await appModel.showProfilesMenu();
    await _loadProfileName();
  }

  /// 顶栏标题：「词典」+ 激活配置名副标题（可聚焦、Enter 打开配置管理）。本页的开关 /
  /// 顺序都属于激活配置，不写明是哪一份配置，用户分不清改的是谁。
  Widget _buildTitle() {
    final String? profile = _profileName;
    final Widget title = Text(
      t.dictionaries,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (profile == null) return title;
    final String label = t.dictionary_manager_profile_subtitle(name: profile);
    final Widget subtitle = FushiTooltip(
      message: t.dictionary_manager_profile_tooltip,
      child: FushiTextButton(
        key: const ValueKey<String>('dict-profile-subtitle'),
        onPressed: () => unawaited(_openProfiles()),
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 24),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: textTheme.labelSmall,
        ),
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[title, subtitle],
      ),
    );
  }

  /// 有参与查词的服务器词典（来源标签、筛选条、host 提示只在这时出现——没配服务器
  /// 的用户看到的列表与改造前一致）。
  bool get _hasServerRows => appModel.remoteDictionaries.isNotEmpty;

  /// 列表里至少有一行（本机或服务器）。
  bool get _hasAnyRows => appModel.dictionaries.isNotEmpty || _hasServerRows;

  String _hostName(String hostId) => _hostNames[hostId] ?? hostId;

  /// 开着「用它查词典」的已配对 host 数：两台及以上时来源 chip 才写设备名。
  int get _lookupHostCount => <String>{
    for (final RemoteDictionaryHostSource h in _hostSources)
      if (h.lookupEnabled) h.hostId,
    for (final RemoteDictionary r in appModel.remoteDictionaries) r.hostId,
  }.length;

  /// [hostId] 上次查词没有套用本端发去的词典选择（老版本 host）。
  bool _olderHost(String hostId) =>
      appModel.remoteDictionaryConfigAppliedByHost[hostId] == false;

  /// 参与查词、目录里也有 [name]（没缺席）的服务器词典，按管理页顺序。「两者」行
  /// 详情与版本对比用排在最前的那份（查词名单里同名只认一份）。
  List<RemoteDictionary> _serverCopiesOf(String name) => <RemoteDictionary>[
    for (final RemoteDictionary r in appModel.remoteDictionaries)
      if (r.name == name && !r.isMissing) r,
  ];

  /// 本机词典的版本号（与行副标题同一来源）；没有为空串。
  String _localRevision(Dictionary dictionary) =>
      (dictionary.metadata['revision'] ??
              dictionary.metadata['version'] ??
              dictionary.metadata['formatVersion'] ??
              '')
          .trim();

  /// 内容语言文案：本机与服务器词典同一个格式（手动指定 > 「自动 · 语言」> 「自动」）。
  String _languageLabel({String? override, String? source}) {
    final String o = override?.trim() ?? '';
    final String src = source?.trim() ?? '';
    if (o.isNotEmpty) return contentLanguageLabelOf(o);
    if (src.isNotEmpty) {
      return '${t.dict_language_auto} · ${contentLanguageLabelOf(src)}';
    }
    return t.dict_language_auto;
  }

  /// 来源标签上的 host 名：服务器行是它所在的 host，「两者」行是也有它的那些 host。
  String _sourceHostName(DictionaryManagerRow row) {
    final RemoteDictionary? remote = row.remote;
    if (remote != null) return _hostName(remote.hostId);
    return row.alsoOnHosts.map(_hostName).join(', ');
  }

  /// 参与查词的服务器词典所在的 host（按列表里首次出现排）。
  List<String> get _serverHostIds => <String>{
    for (final RemoteDictionary r in appModel.remoteDictionaries) r.hostId,
  }.toList();

  /// 生效的来源筛选：选中的服务器已不在（解除配对 / 关掉查词）或已没有服务器词典时
  /// 回落「全部」，不让列表停在一个看不见的筛选上。
  DictionarySourceFilter get _effectiveSourceFilter {
    if (!_hasServerRows) return DictionarySourceFilter.all;
    final DictionarySourceFilter filter = _sourceFilter;
    if (filter.kind == DictionarySourceFilterKind.server &&
        !_serverHostIds.contains(filter.hostId)) {
      return DictionarySourceFilter.all;
    }
    return filter;
  }

  /// 一个分区的混排行（本机词典 + 只在服务器上的词典，见 [mixDictionaryManagerRows]）。
  ///
  /// 「汉字」分区不混服务器词典：混合词典的汉字部分在那里按独立的
  /// [Dictionary.kanjiSectionOrder] 排，与服务器词典的 `order` 不在一条数轴上，
  /// 混排写回会把两套序号搅在一起。
  List<DictionaryManagerRow> _rowsForType(DictionaryType type) {
    final List<Dictionary> local = _dictionariesForType(type);
    final List<RemoteDictionary> serverRows = type == DictionaryType.kanji
        ? const <RemoteDictionary>[]
        : appModel.remoteDictionaries;
    if (serverRows.isEmpty) {
      return <DictionaryManagerRow>[
        for (final Dictionary d in local) DictionaryManagerRow.local(d),
      ];
    }
    return mixDictionaryManagerRows(
      localSection: local,
      allLocal: appModel.dictionaries,
      remote: serverRows,
      sectionType: type,
      localOrder: (Dictionary d) => d.order,
    );
  }

  /// 这一行在当前分区是否参与查词。
  bool _rowEnabled(DictionaryManagerRow row) {
    final RemoteDictionary? remote = row.remote;
    if (remote != null) return !remote.hidden;
    return _enabledInSection(row.local!);
  }

  /// 参与查词的服务器词典里，此刻只在服务器上（单独成行）的那些。
  List<RemoteDictionary> _serverOnlyDictionaries() => <RemoteDictionary>[
    for (final DictionaryType type in const <DictionaryType>[
      DictionaryType.term,
      DictionaryType.frequency,
      DictionaryType.pitch,
    ])
      for (final DictionaryManagerRow row in _rowsForType(type))
        if (row.remote != null) row.remote!,
  ];

  RemoteDictionary? _findRemote(String key) {
    if (!key.startsWith(kDictionaryManagerServerKeyPrefix)) return null;
    for (final RemoteDictionary r in appModel.remoteDictionaries) {
      if (DictionaryManagerRow.remote(r).key == key) return r;
    }
    return null;
  }

  Future<void> _refreshServerDictionaries() async {
    final catalog = appModel.remoteDictionaryCatalog;
    if (catalog == null || _refreshingServer) return;
    setState(() => _refreshingServer = true);
    try {
      await catalog.refresh();
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryDialog.refreshServer', e, stack);
    } finally {
      if (mounted) setState(() => _refreshingServer = false);
    }
  }

  /// 来源筛选条：全部 / 本机 / 每台服务器 / 已隐藏（两台及以上服务器时 + 刷新全部）。
  Widget _buildSourceFilterBar() {
    return DictionarySourceFilterBar(
      key: const ValueKey<String>('dict-source-filter-bar'),
      hosts: <String, String>{
        for (final String id in _serverHostIds) id: _hostName(id),
      },
      selected: _effectiveSourceFilter,
      // 换筛选收回详情：侧板不能停在一本此刻列表里看不见的词典上。
      onSelected: (DictionarySourceFilter filter) => setState(() {
        _sourceFilter = filter;
        _detailName = null;
      }),
      // 单台服务器的刷新住在它的来源卡片上；两台及以上才在筛选条给「刷新全部」。
      onRefresh:
          appModel.remoteDictionaryCatalog == null || _hostSources.length < 2
          ? null
          : _refreshServerDictionaries,
      refreshing: _refreshingServer,
    );
  }

  /// 一台 host 的状态行：本次运行里连不上 → 「连不上 · <多久以前>」；拉到过 → 「在线」；
  /// 还没试过 → 「最近在线 <多久以前>」。卡片上只放相对时间（完整时间戳在默认宽度
  /// 下会被截断），完整时刻进 [DictionaryServerSourceCard.statusTooltip]。
  ({String label, String? tooltip}) _hostStatus(
    RemoteDictionaryHostSource host,
  ) {
    final RemoteDictionaryHostReachability? reach =
        appModel.remoteDictionaryHostReachability[host.hostId];
    final int? failing = reach?.failingSince;
    if (failing != null) {
      return (
        label: t.dictionary_source_status_unreachable_ago(
          time: _relativeTimeLabel(failing),
        ),
        tooltip: t.dictionary_source_status_unreachable(
          time: dictionaryManagerTimestampLabel(failing),
        ),
      );
    }
    if (reach?.lastOkAt != null) {
      return (label: t.dictionary_source_status_online, tooltip: null);
    }
    int seen = 0;
    for (final RemoteDictionary r in host.catalog) {
      if (r.lastSeenAt > seen) seen = r.lastSeenAt;
    }
    return (
      label: t.dictionary_source_status_last_seen(
        time: _relativeTimeLabel(seen),
      ),
      tooltip: t.dictionary_source_status_last_seen(
        time: dictionaryManagerTimestampLabel(seen),
      ),
    );
  }

  /// 「3 分钟前」式相对时间（与动态流同一套推导与文案）。
  static String _relativeTimeLabel(int epochMs) {
    final ActivityRelativeTime rel = activityRelativeTime(
      epochMs,
      DateTime.now(),
    );
    return switch (rel.unit) {
      ActivityRelativeUnit.justNow => t.activity_just_now,
      ActivityRelativeUnit.minutesAgo => t.activity_minutes_ago(n: rel.value),
      ActivityRelativeUnit.hoursAgo => t.activity_hours_ago(n: rel.value),
      ActivityRelativeUnit.daysAgo => t.activity_days_ago(n: rel.value),
    };
  }

  /// 「来源」条此刻该不该出现：有任何一台 host 的目录，且当前筛选能列出服务器行——
  /// 「全部」/「服务器 · 某台」照常出现；「本机」不出现；「已隐藏」只在当前分区里
  /// 确有隐藏的服务器行时出现。还没有服务器行时筛选回落「全部」，条照常出现，
  /// 用户才能在卡片上打开「用于查词」。
  bool get _showServerSourcesStrip {
    if (_hostSources.isEmpty) return false;
    return switch (_effectiveSourceFilter.kind) {
      DictionarySourceFilterKind.all ||
      DictionarySourceFilterKind.server => true,
      DictionarySourceFilterKind.thisDevice => false,
      DictionarySourceFilterKind.hidden => _visibleRows().any(
        (DictionaryManagerRow row) => row.isRemote,
      ),
    };
  }

  /// 列表上方的「来源」条（见 [_showServerSourcesStrip]）。
  Widget _buildServerSourcesStrip() {
    return DictionaryServerSourcesStrip(
      key: const ValueKey<String>('dict-server-sources'),
      cards: <DictionaryServerSourceCard>[
        for (final RemoteDictionaryHostSource host in _hostSources)
          if (_hostStatus(host) case (
            label: final String status,
            tooltip: final String? statusTooltip,
          ))
            DictionaryServerSourceCard(
              hostId: host.hostId,
              name: host.name,
              status: status,
              statusTooltip: statusTooltip,
              enabled: host.catalog
                  .where(
                    (RemoteDictionary r) =>
                        r.type == _selectedType && !r.isMissing && !r.hidden,
                  )
                  .length,
              total: host.catalog
                  .where(
                    (RemoteDictionary r) =>
                        r.type == _selectedType && !r.isMissing,
                  )
                  .length,
              lookupEnabled: host.lookupEnabled,
              olderHost: _olderHost(host.hostId),
              refreshing: _refreshingHosts.contains(host.hostId),
            ),
      ],
      onLookupChanged: (String hostId, bool enabled) => unawaited(
        _saveDictionaryChange(
          () => appModel.setRemoteDictionaryHostLookupEnabled(hostId, enabled),
        ),
      ),
      onRefresh: appModel.canRefreshRemoteDictionaries
          ? (String hostId) => unawaited(_refreshServerHost(hostId))
          : null,
    );
  }

  Future<void> _refreshServerHost(String hostId) async {
    if (_refreshingHosts.contains(hostId)) return;
    setState(() => _refreshingHosts.add(hostId));
    try {
      await appModel.refreshRemoteDictionaryHost(hostId);
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryDialog.refreshHost', e, stack);
    } finally {
      if (mounted) setState(() => _refreshingHosts.remove(hostId));
    }
    await _loadServerSources();
  }

  /// [host] 上（没缺席的）汉字词典本数。服务器上的汉字词典暂时不在「汉字」分区里
  /// 管理（与本机汉字部分的独立序号不在一条数轴上，见 [_rowsForType]）。
  static int _serverKanjiCountOf(RemoteDictionaryHostSource host) => host
      .catalog
      .where(
        (RemoteDictionary r) => r.type == DictionaryType.kanji && !r.isMissing,
      )
      .length;

  /// 服务器上有、但 [type] 分区不列成行的本数（只有「汉字」分区有，按 host 加总，
  /// 与 [_buildKanjiServerNotes] 的各条说明同一口径）。
  int _unlistedServerCount(DictionaryType type) {
    if (type != DictionaryType.kanji) return 0;
    int n = 0;
    for (final RemoteDictionaryHostSource host in _hostSources) {
      n += _serverKanjiCountOf(host);
    }
    return n;
  }

  /// 「汉字」分区：服务器上的汉字词典按 host 各说一行有几本，免得用户以为它们丢了。
  List<Widget> _buildKanjiServerNotes() {
    if (_selectedType != DictionaryType.kanji) return const <Widget>[];
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    return <Widget>[
      for (final RemoteDictionaryHostSource host in _hostSources)
        if (_serverKanjiCountOf(host) case final int n when n > 0)
          Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: FushiInlineNotice(
              key: ValueKey<String>('dict-kanji-server-note-${host.hostId}'),
              icon: FushiIcons.info,
              severity: FushiNoticeSeverity.info,
              message: t.dictionary_server_kanji_unmanaged(
                n: n,
                name: host.name,
              ),
            ),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Apple 设计系统（iOS 26 / macOS 26）与 Cupertino 渲染一样把导入 / 更新 / 清空
    // 放进标题栏动作（桌面一排玻璃圆钮、窄屏「…」溢出菜单），不再在内容层铺一排
    // MD3 tonal 按钮——iOS 的「添加」类动作住在导航栏，内容层只放列表。
    final bool cupertino =
        isCupertinoPlatform(context) || isGlassDesign(context);
    final double width = MediaQuery.sizeOf(context).width;
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    // 宽屏（PC）= 列表 + 右侧详情侧板两栏；窄屏 = 单列卡片列表 + 底部 sheet。
    final bool split = dictionaryManagerUsesSplitLayout(width);
    final List<Widget> actions = cupertino
        ? (compact ? _buildMobilePageActions() : _buildDesktopPageActions())
        : const <Widget>[];
    final List<Widget> listChildren = <Widget>[
      if (!cupertino) _buildActionBar(compact: compact),
      // 收进后台的下载/更新任务的回程入口（BUG-1499）；无任务时是零高度。
      _buildDownloadStatusRow(),
      if (_hasAnyRows) _buildCategorySelector(),
      // 「来源」条：每台有目录的服务器一张卡片（状态 / 本数 / 用于查词 / 刷新），
      // 取代以前列表底部的按 host 提示。
      if (_showServerSourcesStrip) _buildServerSourcesStrip(),
      // 服务器词典的来源筛选：与类型分段同属「筛列表」，紧跟其后。
      if (_hasServerRows) _buildSourceFilterBar(),
      buildContent(),
      // TODO-1075：自动更新设置卡移到词典列表之后（页尾设置区），不再横切
      // 「导入/浏览/清空」高频操作与分类选择器之间的操作动线。宽屏它住进右侧
      // 概览面板（见 _buildDetailPane）。
      if (!split) _buildAutoUpdateCard(),
    ];
    // 桌面三端：整页包一层文件拖放区，把拖入的词典包接到与「导入词典」按钮同源的
    // 导入路径（TODO-059）。移动端 FushiFileDropTarget 直接透传 child，零开销。
    return FushiFileDropTarget(
      debugLabel: 'dictionary-dialog',
      onDrop: _handleDictionaryDrop,
      child: split
          ? FushiToolScaffold.customTitle(
              title: _buildTitle(),
              actions: actions,
              body: _buildSplitBody(listChildren),
            )
          : AdaptiveSettingsScaffold(
              title: _buildTitle(),
              // Cupertino (iOS/macOS) keeps its native nav-bar icon actions.
              // Material (Android/Windows/Linux) empties the app bar and
              // surfaces the same actions as labeled buttons in an in-page
              // action bar so they read as normal buttons instead of bare icons.
              actions: actions,
              bottom: _buildBatchBar(),
              children: listChildren,
            ),
    );
  }

  /// 宽屏两栏：左列表（独立滚动）+ 右详情侧板（独立滚动）；多选态的批量栏
  /// 钉在左列底部。
  Widget _buildSplitBody(List<Widget> listChildren) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gutter = tokens.spacing.rowHorizontal;
    final Widget? batchBar = _buildBatchBar();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: Column(
            children: <Widget>[
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(gutter, 8, gutter, gutter),
                  children: listChildren,
                ),
              ),
              if (batchBar != null) batchBar,
            ],
          ),
        ),
        const FushiVerticalDivider(width: 1),
        SizedBox(
          width: kDictionaryManagerDetailPaneWidth,
          child: _buildDetailPane(),
        ),
      ],
    );
  }

  /// TODO-861③（移植 Hoshi `94d0c41`）：词典自动更新设置卡——「自动更新」开关 +
  /// 检查周期分段（开时显示）+「上次成功检查」只读行。仅 startup check-due（MVP，无
  /// 计费网络门控）。开关默认 **false**（opt-in，不在升级后静默联网/自动重导词典，
  /// 与 [PreferencesRepository.autoUpdateDictionaries] 的 defaultValue: false 对齐；
  /// TODO-1075 修正原「默认 true」误注释）。
  Widget _buildAutoUpdateCard() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool autoUpdate = appModel.autoUpdateDictionaries;
    final DictionaryUpdateInterval interval = appModel.dictionaryUpdateInterval;
    final DateTime? lastUpdate = appModel.lastDictionaryUpdateAt;
    final String lastUpdateText = lastUpdate == null
        ? t.dict_auto_update_never
        : lastUpdate.toLocal().toString().split('.').first;
    // TODO-1343：自动更新设置卡与上方词典列表之间补一段顶部间距。
    // AdaptiveSettingsScaffold 的 children 之间不插任何间隔，靠每个子块自带
    // 分隔（action bar / 分类选择器都用 gap+gap/2 的底部间距分隔下一块）；
    // 而 buildContent()（词典列表）没有底部间距、本卡原来又只有底部间距，
    // 于是列表最后一张词典卡与本卡直接贴在一起（用户报「自动更新和词典粘一
    // 块了」）。这里给本卡补上与其它分块一致的 gap+gap/2 顶部分隔，消除粘连。
    return Padding(
      padding: EdgeInsets.only(
        top: tokens.spacing.gap + tokens.spacing.gap / 2,
        bottom: tokens.spacing.gap,
      ),
      // 设置分组（不是自绘卡片里塞 SwitchListTile + 裸分段 + 列表项）：MD3 下是
      // Android 16 分段分组卡，Apple 下是 inset grouped 分组 + 行分隔线，与设置
      // 页其它分组同一套行组件，开关 / 分段 / 只读行各自按设计系统渲染。
      child: AdaptiveSettingsSection(
        children: <Widget>[
          AdaptiveSettingsSwitchRow(
            title: t.dict_auto_update,
            // 开着时下一行的分段标题就是这句说明，不再在开关下重复一遍。
            subtitle: autoUpdate ? null : t.dict_auto_update_hint,
            icon: Icons.update_outlined,
            showIcon: true,
            value: autoUpdate,
            onChanged: (bool value) async {
              await appModel.setAutoUpdateDictionaries(value);
              if (mounted) setState(() {});
            },
          ),
          if (autoUpdate)
            AdaptiveSettingsSegmentedRow<DictionaryUpdateInterval>(
              title: t.dict_auto_update_hint,
              controlBelow: false,
              segments: <ButtonSegment<DictionaryUpdateInterval>>[
                ButtonSegment<DictionaryUpdateInterval>(
                  value: DictionaryUpdateInterval.daily,
                  label: Text(t.dict_update_interval_daily),
                ),
                ButtonSegment<DictionaryUpdateInterval>(
                  value: DictionaryUpdateInterval.weekly,
                  label: Text(t.dict_update_interval_weekly),
                ),
                ButtonSegment<DictionaryUpdateInterval>(
                  value: DictionaryUpdateInterval.monthly,
                  label: Text(t.dict_update_interval_monthly),
                ),
              ],
              selected: interval,
              onChanged: (DictionaryUpdateInterval value) async {
                await appModel.setDictionaryUpdateInterval(value);
                if (mounted) setState(() {});
              },
            ),
          AdaptiveSettingsRow(
            title: t.dict_auto_update_last(time: lastUpdateText),
            icon: Icons.schedule_outlined,
            showIcon: true,
          ),
        ],
      ),
    );
  }

  /// Material in-page action bar（M3 Expressive）。按使用频率分层，不再一排五个
  /// 等权按钮：
  /// - 主操作「导入词典」是实心主色按钮，「下载推荐」tonal 紧随其后——两个最常用
  ///   的入口一步可达；
  /// - 「导入文件夹 / 更新全部」宽屏直接铺开，窄屏收进行尾溢出菜单；
  /// - 破坏性的「删除所有」一律进溢出菜单，不再与常用操作并排（误触代价太高）；
  /// - 行尾是多选开关（进入批量启用 / 停用 / 删除）。
  Widget _buildActionBar({required bool compact}) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double gap = tokens.spacing.gap;
    if (compact) {
      // 手机：两个主入口各占半行（不再折成两行按钮）；多选开关与溢出菜单挪到
      // 列表头右侧（见 _buildListHeader）。一本词典都没有时没有列表头，溢出菜单
      // （导入文件夹等）留在这里。
      return Padding(
        padding: EdgeInsets.only(
          bottom: tokens.spacing.gap + tokens.spacing.gap / 2,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: _buildActionButton(
                focusPrefix: 'dict-action-file',
                icon: Icons.upload_file_outlined,
                label: t.dialog_import_dictionary,
                onTap: _importDictionaryFiles,
                primary: true,
              ),
            ),
            SizedBox(width: gap),
            Expanded(
              child: _buildActionButton(
                focusPrefix: 'dict-action-download',
                icon: Icons.cloud_download_outlined,
                label: t.dict_download_browse,
                onTap: _showDownloadSelectionDialog,
              ),
            ),
            if (appModel.dictionaries.isEmpty)
              _buildOverflowMenu(compact: true),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(
        bottom: tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Wrap(
              spacing: gap,
              runSpacing: gap,
              children: <Widget>[
                _buildActionButton(
                  focusPrefix: 'dict-action-file',
                  icon: Icons.upload_file_outlined,
                  label: t.dialog_import_dictionary,
                  onTap: _importDictionaryFiles,
                  primary: true,
                ),
                _buildActionButton(
                  focusPrefix: 'dict-action-download',
                  icon: Icons.cloud_download_outlined,
                  label: t.dict_download_browse,
                  onTap: _showDownloadSelectionDialog,
                ),
                if (!compact) ...<Widget>[
                  // Folder import is unavailable on iOS. This bar only renders
                  // on Material, so the guard is a no-op on a normal iOS device;
                  // it stays live only for a forced Material design-system
                  // override on iOS, mirroring _buildDesktopPageActions.
                  if (!Platform.isIOS)
                    _buildActionButton(
                      focusPrefix: 'dict-action-folder',
                      icon: Icons.drive_folder_upload_outlined,
                      label: t.dialog_import_folder,
                      onTap: _importDictionaryFolder,
                    ),
                  // TODO-609：一键更新全部可在线更新的词典（逐本比 revision，有新版
                  // 才下）。常驻显示：没有可更新词典时点了会明确告诉原因。
                  _buildActionButton(
                    focusPrefix: 'dict-action-update',
                    icon: Icons.system_update_alt,
                    label: t.dict_update_all,
                    onTap: _checkForUpdates,
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: gap / 2),
          _buildSelectionToggle(),
          _buildOverflowMenu(compact: false),
        ],
      ),
    );
  }

  Widget _buildOverflowMenu({required bool compact}) {
    return FushiOverflowMenu<VoidCallback>(
      tooltip: t.show_options,
      icon: Icons.more_vert,
      onSelected: (VoidCallback action) => action(),
      items: _buildOverflowItems(includeSecondaryImports: compact),
    );
  }

  /// 溢出菜单里的动作。[includeSecondaryImports] = 页面上没有铺开「导入文件夹 /
  /// 更新全部」时（窄屏、Apple 窄屏标题栏）把它们也放进来。
  List<FushiPopupMenuItem<VoidCallback>> _buildOverflowItems({
    required bool includeSecondaryImports,
  }) {
    return <FushiPopupMenuItem<VoidCallback>>[
      if (includeSecondaryImports) ...<FushiPopupMenuItem<VoidCallback>>[
        buildPopupItem(
          label: t.dict_update_all,
          icon: Icons.system_update_alt,
          action: _checkForUpdates,
        ),
        if (!Platform.isIOS)
          buildPopupItem(
            label: t.dialog_import_folder,
            icon: Icons.drive_folder_upload_outlined,
            action: _importDictionaryFolder,
          ),
      ],
      buildPopupItem(
        label: t.dialog_clear_all_dictionaries,
        icon: Icons.delete_sweep_outlined,
        color: theme.colorScheme.error,
        action: showDictionaryClearDialog,
      ),
    ];
  }

  /// 多选开关：进入 / 退出批量模式。当前类型一本词典都没有时置灰。
  Widget _buildSelectionToggle() {
    final bool hasRows = _dictionariesForType(_selectedType).isNotEmpty;
    return FushiIconButton(
      key: const ValueKey<String>('dict-selection-toggle'),
      icon: _selecting ? Icons.close : Icons.checklist,
      tooltip: _selecting ? t.dict_selection_exit : t.batch_select,
      selected: _selecting,
      enabled: _selecting || hasRows,
      onTap: _toggleSelecting,
    );
  }

  /// A labeled action button that is mouse/touch tappable and, under a
  /// [FushiFocusRoot], a single gamepad/keyboard focus stop (A/Enter fires
  /// [onTap]). Same idiom as the reader quick-settings action strip: the
  /// underlying button is removed from focus traversal so it does not grab a
  /// competing, unregistered focus node. [primary] = 实心主色（本页主操作），
  /// 否则 tonal。
  Widget _buildActionButton({
    required String focusPrefix,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    final Widget button = primary
        ? FushiFilledButton.icon(
            key: ValueKey<String>(focusPrefix),
            onPressed: onTap,
            icon: FushiIcon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          )
        : FushiFilledButton.tonalIcon(
            key: ValueKey<String>(focusPrefix),
            onPressed: onTap,
            icon: FushiIcon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          );
    if (FushiFocusRoot.maybeControllerOf(context) == null) {
      return button;
    }
    return FushiActivatableFocusTarget(
      focusIdPrefix: focusPrefix,
      onTap: onTap,
      child: ExcludeFocus(child: button),
    );
  }

  List<Widget> _buildDesktopPageActions() {
    return [
      FushiIconButton(
        tooltip: t.dict_update_all,
        icon: Icons.system_update_alt,
        onTap: _checkForUpdates,
      ),
      FushiIconButton(
        tooltip: t.dict_download_browse,
        icon: Icons.cloud_download_outlined,
        onTap: _showDownloadSelectionDialog,
      ),
      if (!Platform.isIOS)
        FushiIconButton(
          tooltip: t.dialog_import_folder,
          icon: Icons.drive_folder_upload_outlined,
          onTap: _importDictionaryFolder,
        ),
      FushiIconButton(
        tooltip: t.dialog_import_dictionary,
        icon: Icons.upload_file_outlined,
        onTap: _importDictionaryFiles,
      ),
      _buildSelectionToggle(),
      FushiIconButton(
        tooltip: t.dialog_clear_all_dictionaries,
        icon: Icons.delete_sweep_outlined,
        enabledColor: theme.colorScheme.error,
        onTap: showDictionaryClearDialog,
      ),
    ];
  }

  List<Widget> _buildMobilePageActions() {
    return [
      FushiIconButton(
        tooltip: t.dialog_import_dictionary,
        icon: Icons.upload_file_outlined,
        onTap: _importDictionaryFiles,
      ),
      _buildSelectionToggle(),
      FushiOverflowMenu<VoidCallback>(
        tooltip: t.show_options,
        icon: Icons.more_vert,
        onSelected: (VoidCallback action) => action(),
        items: [
          buildPopupItem(
            label: t.dict_download_browse,
            icon: Icons.cloud_download_outlined,
            action: _showDownloadSelectionDialog,
          ),
          ..._buildOverflowItems(includeSecondaryImports: true),
        ],
      ),
    ];
  }

  Future<void> showDictionaryClearDialog() {
    return _showDictionaryActionConfirmDialog(
      title: t.dialog_title_dictionary_clear,
      content: t.dialog_content_dictionary_clear,
      confirmLabel: t.dialog_clear,
      run: () => appModel.deleteDictionaries(),
    );
  }

  /// 词典内容语言选择框。选择器 UI 与书籍共用（[showContentLanguagePicker]），
  /// 只有持久化不同：词典写 [Dictionary.languageOverride]，书写 EpubBooks.language。
  Future<void> _showDictionaryLanguageDialog(Dictionary dictionary) {
    return showContentLanguagePicker(
      context: context,
      title: t.dict_language_title,
      description: t.dict_language_description,
      current: dictionary.languageOverride,
      // 自动值 = 词典 index.json 声明的词头语言。旧包/本地包为空串。
      autoDetected: dictionary.sourceLanguage,
      onSelected: (String? tag) => _saveDictionaryChange(
        () => appModel.setDictionaryLanguageOverride(dictionary, tag),
      ),
    );
  }

  /// 给词典改个显示名。落的是 `dictionary_metadata.display_name` 覆盖列，**真名
  /// 不动**——真名是主键、磁盘目录名、C++ 引擎装载路径，还被每词典 CSS、样式规则、
  /// 弹窗 `data-dictionary` 选择器、词典媒体 URL、Anki `{single-glossary-<名>}`
  /// token、存储占用条目 id、同步资产名当键用。改真名会让这些全部静默失配（用户
  /// 样式丢失、图/音 404、已配置的制卡字段失效）。
  ///
  /// 因此改名只贯通「给人看的地方」：本列表、查词弹窗里的词典名标题/频率/音高/
  /// 汉字标签、存储占用明细、CSS 作用域下拉、同步对比对话框。
  Future<void> _renameDictionary(Dictionary dictionary) async {
    final String current = dictionary.effectiveDisplayName;
    final String? name = await showNameInputDialog(
      context: context,
      title: t.dict_rename,
      labelText: t.dict_rename_label,
      initialName: current,
      leadingIcon: Icons.drive_file_rename_outline,
    );
    if (!mounted || name == null || name == current) return;
    await _saveDictionaryChange(
      () => appModel.setDictionaryDisplayName(dictionary, name),
    );
  }

  /// Refresh only committed metadata and surface write failures at the action
  /// boundary. A batch can have committed earlier items before one fails.
  Future<bool> _saveDictionaryChange(Future<void> Function() save) async {
    try {
      await save();
      return true;
    } catch (error, stack) {
      ErrorLogService.instance.log('DictionaryDialog.save', error, stack);
      if (mounted) {
        unawaited(
          showErrorDetails(
            context,
            title: t.dictionary_settings,
            error: '$error\n$stack',
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> showDictionaryDeleteDialog(Dictionary dictionary) {
    return _showDictionaryActionConfirmDialog(
      // 确认框与进度页都是给人看的，用显示名；真正的删除按 `dictionary` 对象走
      // （deleteDictionary 内部用真名找磁盘目录）。
      title: t.dialog_title_dictionary_delete(
        name: dictionary.effectiveDisplayName,
      ),
      content: _deleteConfirmContent(<Dictionary>[dictionary]),
      confirmLabel: t.dialog_delete,
      run: () => appModel.deleteDictionary(dictionary),
      progressName: dictionary.effectiveDisplayName,
    );
  }

  /// 「清空全部词典 / 删除单本词典」共用的确认对话框流程（原为两份逐字复制的
  /// 45 行构造样板，仅差文案与删除调用）：确认后先弹不可关闭的删除进度页
  /// [DictionaryDialogDeletePage]（[progressName] 为 null 时是清空全部的无名
  /// 变体），等 [run] 完成后依次收掉进度页与确认框并刷新列表。
  Future<void> _showDictionaryActionConfirmDialog({
    required String title,
    required String content,
    required String confirmLabel,
    required Future<void> Function() run,
    String? progressName,
  }) async {
    final Widget dialog = DictionaryConfirmationDialog(
      title: Text(title),
      content: Text(content, textAlign: TextAlign.justify),
      actions: <Widget>[
        adaptiveDialogAction(
          context: context,
          child: Text(confirmLabel),
          onPressed: () async {
            showAppDialog(
              barrierDismissible: false,
              context: context,
              builder: (context) =>
                  DictionaryDialogDeletePage(name: progressName),
            );

            Object? failure;
            StackTrace? failureStack;
            try {
              await run();
            } catch (e, stack) {
              // 删除抛异常（DB 被占用、文件 IO 失败）时也必须往下走收尾：进度页是
              // `barrierDismissible: false` + `PopScope(canPop: false)`，iOS 没有
              // 系统返回键、侧滑又被 canPop 关掉，异常路径不 pop 就是把用户永久
              // 锁在转圈框里，只能杀进程。
              ErrorLogService.instance.log('DictionaryDialog.delete', e, stack);
              failure = e;
              failureStack = stack;
            }

            if (mounted) {
              Navigator.pop(context);
            }

            if (mounted) {
              Navigator.pop(context);
              setState(() {});
            }

            if (failure != null && mounted) {
              unawaited(
                showErrorDetails(
                  context,
                  title: title,
                  error: '$failure\n$failureStack',
                ),
              );
            }
          },
        ),
        adaptiveDialogAction(
          context: context,
          child: Text(t.dialog_cancel),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );

    showAppDialog(context: context, builder: (context) => dialog);
  }

  Future<void> _importDictionaryFiles() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await FilePicker.platform.clearTemporaryFiles();
    }
    if (!mounted) return;

    final List<String> paths = await pickSystemFilePaths(
      context: context,
      allowedExtensions: const <String>{'zip', 'dsl', 'mdx', 'ifo', 'css'},
    );
    if (paths.isEmpty) return;
    await _importDictionaryPaths(paths);

    if (Platform.isAndroid || Platform.isIOS) {
      await FilePicker.platform.clearTemporaryFiles();
    }
  }

  /// 把一组词典文件路径导入。文件选择器与桌面拖放共用这一条路径（与「导入词典」
  /// 按钮完全同源，不另起炉灶）：把 `.css` 拆成随词典的样式附件，其余按词典包逐个
  /// 经 [AppModel.importDictionary] 导入，复用同一进度对话框 / 失败汇总 / 内存不足
  /// 提示。无任何可导入的词典包时直接返回（不弹空进度框）。
  Future<void> _importDictionaryPaths(List<String> paths) async {
    final List<File> cssFiles = paths
        .where((String pth) => pth.toLowerCase().endsWith('.css'))
        .map((String pth) => File(pth))
        .toList();
    final List<File> dictFiles = paths
        .where((String pth) => !pth.toLowerCase().endsWith('.css'))
        .map((String pth) => File(pth))
        .toList();

    if (dictFiles.isEmpty) return;

    final ValueNotifier<String> progressNotifier = ValueNotifier<String>(
      t.import_start,
    );
    final ValueNotifier<int?> countNotifier = ValueNotifier<int?>(null);
    final ValueNotifier<int?> totalNotifier = ValueNotifier<int?>(null);

    if (!mounted) return;
    showAppDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => DictionaryDialogImportPage(
        progressNotifier: progressNotifier,
        countNotifier: countNotifier,
        totalNotifier: totalNotifier,
      ),
    );
    // TODO-082：导入一开始就给用户一个明确反馈（开始后台导入），不只让用户盯着
    // 模态进度框猜测进度。
    FushiToast.show(msg: t.dict_import_started, severity: ToastSeverity.info);

    bool hadMemoryError = false;
    final List<DictionaryTaskFailure> failures = <DictionaryTaskFailure>[];

    totalNotifier.value = dictFiles.length;
    for (int i = 0; i < dictFiles.length; i++) {
      countNotifier.value = i + 1;

      final File file = dictFiles[i];

      // BUG-082: collect per-file failures (no 3s block each) and show one
      // summary after the loop instead of dwelling on every failed import.
      try {
        await appModel.importDictionary(
          progressNotifier: progressNotifier,
          file: file,
          cssFiles: cssFiles,
          onImportSuccess: () {
            if (!mounted) return;
            _selectedType = appModel.dictionaries.last.type;
            setState(() {});
          },
          onMemoryError: () {
            hadMemoryError = true;
          },
        );
      } catch (e, stack) {
        ErrorLogService.instance.log('DictionaryDialog.fileImport', e, stack);
        failures.add(
          DictionaryTaskFailure(
            name: path.basenameWithoutExtension(file.path),
            stage: DictionaryTaskStage.import,
            error: e,
          ),
        );
      }
    }

    if (mounted) {
      Navigator.pop(context);
    }

    if (failures.isNotEmpty) {
      // BUG-2188：文件导入失败同样带全文诊断——原生 toast 会把它截成两行且不可复制。
      // 页面已经销毁（用户导入期间离开）时退回 toast，失败提示不能因此静默丢失。
      final String summary = DictionaryImportManager.formatImportFailureSummary(
        failures,
      );
      if (mounted) {
        unawaited(
          showErrorDetails(
            context,
            title: summary,
            error: DictionaryImportManager.formatFailureDetails(failures),
          ),
        );
      } else {
        FushiToast.show(
          msg: summary,
          toastLength: Toast.LENGTH_LONG,
          severity: ToastSeverity.error,
        );
      }
    }

    // TODO-082：成功导入的词典数 = 总数 - 失败数；> 0 就给一条明确的成功提示
    // （失败的另由上面的失败汇总文案告知，两者可同时出现：部分成功部分失败）。
    final int successCount = dictFiles.length - failures.length;
    if (successCount > 0) {
      FushiToast.show(
        msg: t.dict_import_success_summary(n: successCount),
        severity: ToastSeverity.success,
      );
    }

    if (hadMemoryError && mounted) {
      showAppDialog(
        context: context,
        builder: (context) => const DictionaryLowMemoryDialog(),
      );
    }
  }

  /// 桌面拖放落地处理：把拖入文件按扩展名分类，取出词典包（`.zip`/`.dsl`/`.mdx`）+
  /// 同批拖入的 `.css` 样式附件，交给与「导入词典」按钮同源的 [_importDictionaryPaths]。
  /// 没有词典包时给用户明确反馈；移动端无桌面拖放，[FushiFileDropTarget] 已直接
  /// 透传 child，本回调在移动端永不触发。纯分类逻辑见 [classifyDroppedFilesForDictionary]。
  void _handleDictionaryDrop(List<String> paths, Offset globalPosition) {
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;

    final List<String> importPaths = classifyDroppedFilesForDictionary(paths);
    debugPrint(
      '[fushi-drop] [dictionary-dialog] importPaths=${importPaths.length} '
      'paths=${paths.length} global=$globalPosition',
    );
    if (importPaths.isEmpty) {
      debugPrint('[fushi-drop] [dictionary-dialog] intent=unsupportedSurface');
      FushiToast.show(
        msg: t.drag_drop_unsupported_on_dictionary,
        severity: ToastSeverity.error,
      );
      return;
    }
    _importDictionaryPaths(importPaths);
  }

  bool _isDictInstalled(RecommendedDictionary rec) =>
      isRecommendedDictionaryInstalled(appModel.dictionaries, rec);

  Set<int> _computeInstalledIndices(List<RecommendedDictionary> cat) {
    final Set<int> indices = {};
    for (int i = 0; i < cat.length; i++) {
      if (_isDictInstalled(cat[i])) indices.add(i);
    }
    return indices;
  }

  // HBK-AUDIT-110: build a rec->index map once per catalog so checkbox tiles do
  // an O(1) lookup instead of List.indexOf (O(n)) per checkbox per rebuild.
  Map<RecommendedDictionary, int> _computeRecIndices(
    List<RecommendedDictionary> cat,
  ) {
    final Map<RecommendedDictionary, int> indices =
        <RecommendedDictionary, int>{};
    for (int i = 0; i < cat.length; i++) {
      indices[cat[i]] = i;
    }
    return indices;
  }

  Future<void> _showDownloadSelectionDialog() async {
    if (_isDownloading) return;

    var selectedLang = appModel.appLocale.languageCode;
    if (!DictionaryDownloader.availableLanguages.containsKey(selectedLang)) {
      selectedLang = 'en';
    }
    var selectedLearningLang = 'ja';
    var workingCatalog = DictionaryDownloader.catalogForLearningLang(
      learningLang: selectedLearningLang,
      glossLang: selectedLang,
    );
    var installedIndices = _computeInstalledIndices(workingCatalog);
    var defaults = DictionaryDownloader.defaultSelectionForLearningLang(
      learningLang: selectedLearningLang,
      glossLang: selectedLang,
      workingCatalog: workingCatalog,
    );
    var checked = Set<int>.from(defaults.difference(installedIndices));
    // HBK-AUDIT-110: byCategory and the rec->index map depend only on
    // workingCatalog, not on checkbox toggles. Compute them here (and again
    // only when the language changes) so per-toggle setDialogState rebuilds
    // don't re-derive the grouping or run O(n) catalog.indexOf per checkbox.
    var byCategory = DictionaryDownloader.byCategoryFrom(workingCatalog);
    var recIndex = _computeRecIndices(workingCatalog);
    // 学习语言/释义语言任一变化都重建整个目录派生状态。
    void recomputeCatalogState() {
      workingCatalog = DictionaryDownloader.catalogForLearningLang(
        learningLang: selectedLearningLang,
        glossLang: selectedLang,
      );
      byCategory = DictionaryDownloader.byCategoryFrom(workingCatalog);
      recIndex = _computeRecIndices(workingCatalog);
      installedIndices = _computeInstalledIndices(workingCatalog);
      defaults = DictionaryDownloader.defaultSelectionForLearningLang(
        learningLang: selectedLearningLang,
        glossLang: selectedLang,
        workingCatalog: workingCatalog,
      );
      checked = Set<int>.from(defaults.difference(installedIndices));
    }

    final Set<DictionaryCategory> expandedCategories = <DictionaryCategory>{
      DictionaryCategory.jaEn,
      DictionaryCategory.jaJa,
      DictionaryCategory.bilingual,
      DictionaryCategory.monolingual,
    };

    final selected = await showAppDialog<Set<int>>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final int downloadCount = checked.length;
            final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
            return DictionaryDownloadSelectionDialogFrame(
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildLanguageSelector(
                      label: t.dict_download_learning_language,
                      selectedLang: selectedLearningLang,
                      onChanged: (String lang) {
                        setDialogState(() {
                          selectedLearningLang = lang;
                          recomputeCatalogState();
                        });
                      },
                    ),
                    SizedBox(height: tokens.spacing.gap),
                    _buildLanguageSelector(
                      label: t.dict_download_language,
                      selectedLang: selectedLang,
                      onChanged: (String lang) {
                        setDialogState(() {
                          selectedLang = lang;
                          // HBK-AUDIT-110: recompute the catalog-derived
                          // structures only when the language (hence catalog)
                          // actually changes.
                          recomputeCatalogState();
                        });
                      },
                    ),
                    SizedBox(height: tokens.spacing.gap),
                    DictionaryCatalogSelectionList(
                      workingCatalog: workingCatalog,
                      byCategory: byCategory,
                      recIndex: recIndex,
                      installedIndices: installedIndices,
                      checked: checked,
                      expandedCategories: expandedCategories,
                      onCheckedChanged: (Set<int> next) =>
                          setDialogState(() => checked = next),
                      onExpansionChanged:
                          (DictionaryCategory cat, bool expanded) =>
                              setDialogState(() {
                                if (expanded) {
                                  expandedCategories.add(cat);
                                } else {
                                  expandedCategories.remove(cat);
                                }
                              }),
                    ),
                  ],
                ),
              ),
              actions: [
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: () => Navigator.pop(ctx, null),
                  child: Text(t.dialog_cancel),
                ),
                adaptiveDialogAction(
                  context: ctx,
                  onPressed: downloadCount > 0
                      ? () => Navigator.pop(ctx, checked)
                      : null,
                  child: Text(
                    t.dict_download_button(count: downloadCount.toString()),
                  ),
                ),
              ],
            );
          },
        );
      },
    );

    if (selected == null || selected.isEmpty || !mounted) return;

    final toDownload = selected.map((i) => workingCatalog[i]).toList();

    if (toDownload.isEmpty) return;
    await _downloadSelectedDictionaries(toDownload);
  }

  Widget _buildLanguageSelector({
    required String label,
    required String selectedLang,
    required ValueChanged<String> onChanged,
  }) {
    const Map<String, String> langs = DictionaryDownloader.availableLanguages;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Row(
      children: [
        Text(label, style: tokens.type.controlLabel),
        SizedBox(width: tokens.spacing.gap),
        Expanded(
          child: GamepadMenuDropdown<String>(
            selected: selectedLang,
            onChanged: onChanged,
            entries: <GamepadDropdownEntry<String>>[
              for (final MapEntry<String, String> e in langs.entries)
                (value: e.key, label: e.value),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _downloadSelectedDictionaries(
    List<RecommendedDictionary> toDownload,
  ) async {
    final Directory tempDir = Directory(
      path.join(appModel.dictionaryResourceDirectory.path, 'download_temp'),
    );

    // BUG-927：逐本下载失败不再只压成一个 2 秒就消失的进度文案——收集失败的词典名
    // 与原因，循环后弹一条持久可见（LENGTH_LONG）的失败汇总，并把完整诊断（异常 +
    // 栈 + URL）写进 ErrorLogService（错误日志页可查、可回传），与「导入词典」按钮的
    // 文件导入路径（_importDictionaryPaths）同一套「记日志 + 汇总 toast」反馈。
    final List<DictionaryTaskFailure> failures = <DictionaryTaskFailure>[];

    await _runWithDownloadProgressDialog(
      initialMessage: t.import_start,
      body: (DictionaryDownloadJob job) async {
        final ValueNotifier<String> progressNotifier = job.message;
        final ValueNotifier<double> downloadProgress = job.progress;
        int successCount = 0;
        bool cancelled = false;

        try {
          for (final RecommendedDictionary rec in toDownload) {
            // BUG-1499：本间边界是**除下载传输之外唯一安全的中断时点**——上一本已
            // 完整发布、下一本还没碰任何东西，词典库状态与取消前完全一致。
            if (job.isCancelled) {
              cancelled = true;
              break;
            }
            job.markDownloadPhase();
            progressNotifier.value = t.dict_downloading(name: rec.name);
            downloadProgress.value = 0;

            // BUG-2188：区分「下载阶段失败」与「导入阶段失败」。以前两者共用一句
            // 「导入失败」，用户于是先看到下载失败、再看到导入失败，误以为是两次错误。
            bool zipDownloaded = false;
            try {
              await downloadAndImportRecommendedDictionary(
                appModel: appModel,
                rec: rec,
                job: job,
                tempDir: tempDir,
                onBytes: (int received, int total) =>
                    progressNotifier.value = dictionaryDownloadStageMessage(
                      name: rec.name,
                      received: received,
                      total: total,
                    ),
                onDownloaded: () {
                  zipDownloaded = true;
                  // BUG-1493：与单本更新同一套阶段切换（归零进度条 → 不定态），否则
                  // 导入期间进度条定格满格，看起来就是卡死。BUG-1499：同时把取消按钮
                  // 禁掉。可更新性来源回填见 [recommendedDictionarySourceOverride]。
                  enterDictionaryImportStage(
                    name: rec.name,
                    progressNotifier: progressNotifier,
                    downloadProgress: downloadProgress,
                    job: job,
                  );
                },
              );
              successCount++;
            } catch (e, st) {
              // 取消不是失败：不记错误日志、不计进失败汇总，只停整批。
              if (DictionaryDownloadController.isCancellation(e)) {
                cancelled = true;
                break;
              }
              // 完整诊断进错误日志（含异常类型 / URL / 栈），不再被静默吞掉。
              ErrorLogService.instance.log(
                'DictionaryDialog.download',
                '${e.runtimeType} 下载/导入「${rec.name}」失败（${rec.url}）：$e',
                st,
              );
              // BUG-2188：异常本体一路带到渲染层。以前这里只留下名字，原因在这
              // 一行就永久丢失了——后面无论怎么改 UI 都救不回来。
              failures.add(
                DictionaryTaskFailure(
                  name: rec.name,
                  stage: zipDownloaded
                      ? DictionaryTaskStage.import
                      : DictionaryTaskStage.download,
                  error: e,
                  url: rec.url,
                ),
              );
            }
          }

          // BUG-2188：**标题保持短**（它渲染在 `maxLines: 1` 的单行标题里），失败
          // 原因走 `job.detail`，在正文里多行显示。以前把整串 `DioError [connection ...`
          // 塞进标题，用户能看到的恰好是它被截断的前半段。
          final String lastReason = failures.isEmpty
              ? ''
              : failures.last.reason;
          if (cancelled) {
            progressNotifier.value = t.dict_download_cancelled;
          } else if (successCount == toDownload.length) {
            progressNotifier.value = t.dict_download_complete;
          } else if (successCount > 0) {
            progressNotifier.value = t.dict_download_partial(
              success: successCount,
              total: toDownload.length,
              error: '',
            );
            job.detail.value = lastReason;
          } else {
            progressNotifier.value = t.dict_download_failed(error: '');
            job.detail.value = lastReason;
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        } finally {
          // 取消时这一步同时清掉了半个 zip：temp 目录整棵删，不留残渣。
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        }

        // BUG-927：把失败的词典名持久汇总给用户（LENGTH_LONG），而不是只在那个 2 秒
        // 就消失的进度框里一闪而过。BUG-1499：交给 controller 发——用户可能已经收起
        // 进度框离开词典页，这条汇总仍必须送达。
        if (cancelled) {
          return DictionaryDownloadOutcome(
            message: t.dict_download_cancelled,
            severity: ToastSeverity.info,
          );
        }
        if (failures.isNotEmpty) {
          return DictionaryDownloadOutcome(
            message: DictionaryImportManager.formatImportFailureSummary(
              failures,
            ),
            toastLength: Toast.LENGTH_LONG,
            severity: ToastSeverity.error,
            // BUG-2188：全文诊断（含试过哪些地址、原始异常）交给「错误详情」框，
            // 用户可以整段复制去反馈，而不是抄一段被截断的英文。
            details: DictionaryImportManager.formatFailureDetails(failures),
          );
        }
        return null;
      },
    );
  }

  /// 下载/更新词典共用的样板（四处复用：在线下载 [_downloadSelectedDictionaries]、
  /// 单本在线更新 [_updateSingleDictionary]、从文件覆盖更新
  /// [_updateDictionaryFromFile]、批量检查更新 [_checkForUpdates]）。
  ///
  /// BUG-1499：**任务不再属于这个对话框**。以前 notifier 建在这里、`await body(...)`
  /// 在这里、收尾 `Navigator.pop(context)` 也在这里——于是没有任何合法途径把进度框
  /// 收起来（真收起来了，收尾那一 pop 会把词典页本身弹掉），也没有取消入口。现在
  /// 任务交给 app 级 [DictionaryDownloadController]（挂在 [AppModel] 上），本方法只
  /// 负责：忙则拒绝、开一个**视图**、等任务结束刷新列表。视图关掉与否与任务无关。
  Future<void> _runWithDownloadProgressDialog({
    required String initialMessage,
    required Future<DictionaryDownloadOutcome?> Function(
      DictionaryDownloadJob job,
    )
    body,
  }) async {
    final DictionaryDownloadController controller =
        appModel.dictionaryDownloadController;
    if (controller.isBusy) {
      // 忙的原因可能是启动时的静默自动更新（BUG-1500），不是只有本页会占用它，
      // 所以要明确告诉用户「已有下载在跑」而不是静默 return。
      FushiToast.show(msg: t.dict_download_busy, severity: ToastSeverity.info);
      return;
    }
    _showDownloadProgressDialog();
    await controller.run(initialMessage: initialMessage, body: body);
    if (mounted) setState(() {});
  }

  /// 打开进度框视图。可重复调用（收起后从状态行再打开）——同一个 controller，
  /// 同一份进度。
  void _showDownloadProgressDialog() {
    final DictionaryDownloadController controller =
        appModel.dictionaryDownloadController;
    showAppDialog<void>(
      barrierDismissible: false,
      context: context,
      builder: (BuildContext ctx) => DictionaryDownloadProgressAutoCloser(
        phase: controller.phase,
        child: ValueListenableBuilder<String>(
          valueListenable: controller.message,
          builder: (_, String msg, __) => ValueListenableBuilder<bool>(
            valueListenable: controller.cancellable,
            builder: (_, bool cancellable, __) =>
                DictionaryDownloadProgressDialog(
                  message: msg,
                  detailListenable: controller.detail,
                  progressListenable: controller.progress,
                  // 导入阶段 cancellable 为 false → 按钮置灰 + 说明为什么停不下来，
                  // 而不是给一个按了没反应的按钮（BUG-1499）。
                  onCancel: cancellable ? controller.requestCancel : null,
                  cancelDisabledHint: t.dict_download_import_uncancellable,
                  onHide: () => Navigator.of(ctx).pop(),
                ),
          ),
        ),
      ),
    );
  }

  /// BUG-1499：任务被收进后台时，词典页顶部这条状态行是**唯一的回程入口**——没有它
  /// 用户收起来就再也看不到进度了。任务结束（phase 回 idle）自动消失。
  Widget _buildDownloadStatusRow() {
    final DictionaryDownloadController controller =
        appModel.dictionaryDownloadController;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ValueListenableBuilder<DictionaryDownloadPhase>(
      valueListenable: controller.phase,
      builder: (_, DictionaryDownloadPhase phase, __) {
        if (phase == DictionaryDownloadPhase.idle) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: EdgeInsets.only(
            bottom: tokens.spacing.gap + tokens.spacing.gap / 2,
          ),
          child: FushiCard(
            padding: EdgeInsets.zero,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ValueListenableBuilder<String>(
                  valueListenable: controller.message,
                  builder: (_, String msg, __) => FushiListItem(
                    minHeight: 44,
                    leading: const FushiIcon(
                      Icons.cloud_download_outlined,
                      size: 18,
                    ),
                    title: Text(
                      msg.isEmpty ? t.dict_update_checking : msg,
                      style: textTheme.bodySmall,
                    ),
                    titleMaxLines: 2,
                    trailing: FushiTextButton(
                      onPressed: _showDownloadProgressDialog,
                      child: Text(t.dict_download_progress_show),
                    ),
                  ),
                ),
                // 后台任务的进度直接画在回程条里（MD3 Expressive 波浪进度 / Apple
                // 细进度条），不必点开进度对话框才知道跑到哪了；没有进度值时是
                // 不定态。
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.card,
                    0,
                    tokens.spacing.card,
                    tokens.spacing.gap,
                  ),
                  child: ValueListenableBuilder<double>(
                    valueListenable: controller.progress,
                    builder: (_, double progress, __) =>
                        FushiLinearProgressIndicator(
                          value: progress > 0 ? progress : null,
                        ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static const _safChannel = FushiChannels.saf;

  /// 选词典目录。安卓与 iOS 都走原生 `pickAndCopyDirectory`：整目录拷进
  /// [tempDir] 再导入、导完即删。iOS 上 file_picker 的 `getDirectoryPath()` 交回的
  /// 沙盒外路径 `dart:io` 读不了（BUG-2786），只能在安全作用域访问窗口内拷进来。
  ///
  /// 必须用原生**返回的**路径：安卓把目录内容直接拷进 [tempDir]（返回它本身），
  /// iOS 拷成 `tempDir/<文件夹名>`（返回那一层）。清理永远删 [tempDir]。
  Future<({Directory directory, Directory? cleanupDir})?>
  _pickDictionaryImportDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final Directory tempDir = Directory(
        '${appModel.dictionaryResourceDirectory.path}/saf_import_temp',
      );
      final String? result = await _safChannel.invokeMethod<String>(
        'pickAndCopyDirectory',
        {'destPath': tempDir.path},
      );
      if (result == null) return null;
      return (directory: Directory(result), cleanupDir: tempDir);
    }

    final String? selectedPath = await FilePicker.platform.getDirectoryPath();
    if (selectedPath == null) return null;
    return (directory: Directory(selectedPath), cleanupDir: null);
  }

  Future<void> _importDictionaryFolder() async {
    ValueNotifier<String> progressNotifier = ValueNotifier<String>(
      t.import_start,
    );
    ValueNotifier<int?> countNotifier = ValueNotifier<int?>(null);
    ValueNotifier<int?> totalNotifier = ValueNotifier<int?>(null);

    final ({Directory? cleanupDir, Directory directory})? pickedDirectory;
    try {
      pickedDirectory = await _pickDictionaryImportDirectory();
    } on PlatformException catch (e) {
      // 原生拷贝失败（COPY_FAILED / SAF_ERROR / BUSY）不是取消，必须让用户看见。
      debugPrint('[Dictionary Import] folder pick failed: $e');
      FushiToast.show(
        msg: t.import_folder_copy_failed(error: e.message ?? e.code),
        severity: ToastSeverity.error,
      );
      return;
    }
    if (pickedDirectory == null) return;

    if (mounted) {
      showAppDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => DictionaryDialogImportPage(
          progressNotifier: progressNotifier,
          countNotifier: countNotifier,
          totalNotifier: totalNotifier,
        ),
      );
      // TODO-082：目录导入也在开始时给明确反馈（成功/失败提示由
      // DictionaryImportManager.importFromDirectory 在完成时弹出）。
      FushiToast.show(msg: t.dict_import_started, severity: ToastSeverity.info);
    }

    bool hadMemoryError = false;
    String? folderImportError;

    try {
      await appModel.importDictionaryFromDirectory(
        directory: pickedDirectory.directory,
        progressNotifier: progressNotifier,
        countNotifier: countNotifier,
        totalNotifier: totalNotifier,
        onImportSuccess: () {
          if (!mounted) return;
          _selectedType = appModel.dictionaries.last.type;
          setState(() {});
        },
        onMemoryError: () {
          hadMemoryError = true;
        },
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('DictionaryDialog.folderImport', e, stack);
      debugPrint('[Dictionary Import] folder import error: $e');
      // BUG-082: don't block 3s here either — capture and toast after the
      // progress dialog closes, consistent with the multi-file path.
      folderImportError = '$e';
    } finally {
      final Directory? cleanupDir = pickedDirectory.cleanupDir;
      if (cleanupDir != null && cleanupDir.existsSync()) {
        cleanupDir.deleteSync(recursive: true);
      }
    }

    if (mounted) {
      Navigator.pop(context);
    }

    if (folderImportError != null) {
      FushiToast.show(
        msg: folderImportError,
        toastLength: Toast.LENGTH_LONG,
        severity: ToastSeverity.error,
      );
    }

    if (hadMemoryError && mounted) {
      showAppDialog(
        context: context,
        builder: (context) => const DictionaryLowMemoryDialog(),
      );
    }
  }

  /// 当前分区在当前来源筛选下看得见的行（列表与详情侧板共用）。
  List<DictionaryManagerRow> _visibleRows() {
    final DictionarySourceFilter filter = _effectiveSourceFilter;
    return <DictionaryManagerRow>[
      for (final DictionaryManagerRow row in _rowsForType(_selectedType))
        if (filter.matches(row, enabled: _rowEnabled(row))) row,
    ];
  }

  Widget buildContent() {
    if (!_hasAnyRows) return buildEmptyMessage();
    final List<DictionaryManagerRow> rows = _rowsForType(_selectedType);
    final DictionarySourceFilter filter = _effectiveSourceFilter;
    final List<DictionaryManagerRow> visible = _visibleRows();
    final List<Widget> kanjiServerNotes = _buildKanjiServerNotes();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildListHeader(rows, visible: visible),
        ...kanjiServerNotes,
        // 有服务器汉字词典的说明时不再叠一句「导入一本词典」：说明已经讲清这一类
        // 词典在哪，再劝导入就自相矛盾。
        if (visible.isEmpty && kanjiServerNotes.isEmpty)
          _buildEmptyCategoryRow()
        else if (visible.isNotEmpty)
          // 进场窗口：首开、切换词典类型与切换来源筛选时，首屏的组标题与词典行
          // 错峰淡入上移（服务器行与本机行同一条错峰序列）。
          FushiEntranceScope(
            replayKey: '${_selectedType.name}|${filter.id}',
            child: _buildLanguageGroups(visible),
          ),
      ],
    );
  }

  /// 按「有效语言」（手动指定优先，其次包内声明）分组的列表（反馈 D_Nz5R4vSH）：
  /// 每组一个语言名标题 + 一列只能在组内拖动的词典；没有语言信息的归「未标注
  /// 语言」组放最后。分组与组内顺序的推导见 [groupDictionariesByLanguage]——
  /// 组内顺序就是全局查词优先级在该组的子序列；组内重排写回时整个分区按「各组
  /// 首尾相接」重编号（[moveDictionaryWithinLanguageGroup]），所以这里从上到下
  /// 画出来的顺序就是真实查词顺序，其它组的组内顺序不变。
  ///
  /// 只有一个语言组时不画组标题：多数用户只装一种语言的词典，列表保持原样，
  /// 不平白多一行标题；两组及以上才需要标题来区分。
  Widget _buildLanguageGroups(List<DictionaryManagerRow> section) {
    final List<DictionaryManagerLanguageGroup> groups =
        groupDictionaryManagerRowsByLanguage(section);
    final bool showHeaders = groups.length > 1;
    final List<Widget> children = <Widget>[];
    // 错峰下标跨组累加：标题与词典行按屏幕自上而下依次进场。
    int entranceIndex = 0;
    for (int g = 0; g < groups.length; g++) {
      final DictionaryManagerLanguageGroup group = groups[g];
      if (showHeaders) {
        children.add(
          FushiStaggeredEntrance(
            index: entranceIndex++,
            child: _buildLanguageGroupHeader(
              group.language,
              group.rows.length,
              first: g == 0,
            ),
          ),
        );
      }
      children.add(
        _buildDictionaryList(
          group.rows,
          groupKey: group.language,
          entranceOffset: entranceIndex,
        ),
      );
      entranceIndex += group.rows.length;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  /// 组标题：语言自称（与内容语言选择器同一套标签，见 [contentLanguageLabelOf]）
  /// + 本组本数。走 [SettingsSectionHeader]，MD3 / Apple 各按自己的分组外标题排。
  Widget _buildLanguageGroupHeader(
    String? language,
    int count, {
    required bool first,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String label = language == null
        ? t.dict_language_group_unset
        : contentLanguageLabelOf(language);
    return KeyedSubtree(
      key: ValueKey<String>('dict-language-group-${language ?? ''}'),
      child: SettingsSectionHeader(
        t.dict_language_group_title(language: label, n: count),
        padding: EdgeInsets.only(
          top: first ? 0 : tokens.spacing.card,
          bottom: tokens.spacing.gap,
        ),
      ),
    );
  }

  /// [row] 在它所在分区里的语言组（组内顺序，含服务器行）。详情里的上移 / 下移 /
  /// 置顶 / 置底 / 移到第几位与键盘 Alt+↑↓ 都以组为排序范围。
  List<DictionaryManagerRow> _languageGroupRowsOf(DictionaryManagerRow row) {
    final Dictionary? local = row.local;
    final DictionaryType section = local != null
        ? _sectionTypeOf(local)
        : row.remote!.type;
    return dictionaryManagerLanguageGroupOf(_rowsForType(section), row);
  }

  /// 列表头：分类标题 + 「共 N 本 · 已启用 M 本」，右侧是排序方式提示（桌面
  /// 「拖动 / Alt+↑↓」，触屏「长按拖动」）——以前排序全靠用户自己发现。
  Widget _buildListHeader(
    List<DictionaryManagerRow> dictionaries, {
    required List<DictionaryManagerRow> visible,
  }) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // 有来源筛选时计数跟着筛后的行走（「显示 2 / 5 本 · 已启用 2 本」），不然标题说
    // 5 本、下面只有 2 行，像是丢了词典。
    final bool filtered = visible.length != dictionaries.length;
    final int enabledCount = (filtered ? visible : dictionaries)
        .where(_rowEnabled)
        .length;
    final TargetPlatform platform = theme.platform;
    final bool desktop =
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS;
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    // Material 手机：多选开关与溢出菜单住在这一行右侧（动作条只放两个主入口）。
    final bool headerActions =
        compact && !(isCupertinoPlatform(context) || isGlassDesign(context));
    final Widget? hint = dictionaries.length > 1
        ? Text(
            desktop ? t.dict_reorder_hint_desktop : t.dict_reorder_hint_touch,
            style: textTheme.bodySmall?.copyWith(color: scheme.outline),
          )
        : null;
    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spacing.gap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SettingsSectionHeader(
                  _labelForType(_selectedType),
                  padding: EdgeInsets.zero,
                ),
                Text(
                  filtered
                      ? t.dict_manager_summary_filtered(
                          shown: visible.length,
                          n: dictionaries.length,
                          m: enabledCount,
                        )
                      : t.dict_manager_summary(
                          n: dictionaries.length,
                          m: enabledCount,
                        ),
                  key: const ValueKey<String>('dict-list-summary'),
                  style: textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (hint != null && headerActions) hint,
              ],
            ),
          ),
          if (headerActions) ...<Widget>[
            _buildSelectionToggle(),
            _buildOverflowMenu(compact: true),
          ] else if (hint != null)
            hint,
        ],
      ),
    );
  }

  /// 词典类型筛选（术语 / 汉字 / 词频 / 音调），每段带本数。宽窄屏同一个分段
  /// 控件（MD3 Expressive 连接式按钮组 / Apple 分段），窄屏放不下时横向滚动——
  /// 不再在手机上退化成一个要点开才看得到选项的下拉框。
  Widget _buildCategorySelector() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    String label(String name, DictionaryType type) =>
        '$name ${_rowsForType(type).length}';
    return Padding(
      padding: EdgeInsets.only(
        bottom: tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return HorizontalDragScrollable(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                // Wrap as a single gamepad/keyboard focus stop (D-pad Left/Right
                // cycles the category). A bare segmented button is a cluster of
                // unregistered native buttons that the directional focus
                // controller skips over to the dictionary tiles below.
                child: FushiAdjustableSegmented<DictionaryType>(
                  focusIdPrefix: 'dict-type',
                  values: const <DictionaryType>[
                    DictionaryType.term,
                    DictionaryType.kanji,
                    DictionaryType.frequency,
                    DictionaryType.pitch,
                  ],
                  selected: _selectedType,
                  onChanged: _selectType,
                  child: adaptiveSegmentedButton<DictionaryType>(
                    context: context,
                    segments: [
                      ButtonSegment<DictionaryType>(
                        value: DictionaryType.term,
                        label: Text(
                          label(t.dictionary_type_term, DictionaryType.term),
                        ),
                        tooltip: t.dictionary_type_term,
                      ),
                      ButtonSegment<DictionaryType>(
                        value: DictionaryType.kanji,
                        label: Text(
                          label(
                            t.dictionary_section_kanji,
                            DictionaryType.kanji,
                          ),
                        ),
                        tooltip: t.dictionary_section_kanji,
                      ),
                      ButtonSegment<DictionaryType>(
                        value: DictionaryType.frequency,
                        label: Text(
                          label(
                            t.dictionary_type_frequency,
                            DictionaryType.frequency,
                          ),
                        ),
                        tooltip: t.dictionary_type_frequency,
                      ),
                      ButtonSegment<DictionaryType>(
                        value: DictionaryType.pitch,
                        label: Text(
                          label(t.dictionary_type_pitch, DictionaryType.pitch),
                        ),
                        tooltip: t.dictionary_type_pitch,
                      ),
                    ],
                    selected: {_selectedType},
                    onSelectionChanged: (Set<DictionaryType> selection) {
                      if (selection.isEmpty) return;
                      _selectType(selection.first);
                    },
                    style: kSettingsSegmentedStyle,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 切换词典类型：多选只在当前类型内进行，切走即清空选择（避免对看不见的
  /// 词典做批量操作）。
  void _selectType(DictionaryType type) {
    if (type == _selectedType) return;
    setState(() {
      _selectedType = type;
      _selectedNames.clear();
      // 换分区时详情侧板只留在新分区里也看得见的那本（混合词典的术语 / 汉字两部分
      // 是同一行键，BUG-3573 要求停留）；别的分区的词典收回概览（本机行同样适用）。
      final String? detail = _detailName;
      if (detail != null &&
          !_visibleRows().any((DictionaryManagerRow r) => r.key == detail)) {
        _detailName = null;
      }
    });
  }

  Widget buildEmptyMessage() {
    final TargetPlatform platform = theme.platform;
    // 一本词典都没有：说明支持的格式，把「导入」「下载推荐」两个入口直接放在
    // 眼前；桌面再提示可以直接拖进窗口（TODO-059 的拖放导入）。
    return DictionaryManagerEmptyState(
      icon: DictionaryMediaType.instance.outlinedIcon,
      onImport: _importDictionaryFiles,
      onDownload: _showDownloadSelectionDialog,
      showDropHint:
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.linux ||
          platform == TargetPlatform.macOS,
    );
  }

  Widget _buildEmptyCategoryRow() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // Mirror buildEmptyMessage (the all-empty state) so switching to a
    // dictionary-type tab that happens to have no dictionary of that type reads
    // the same: a centred icon + message, not a cramped left-aligned grey card
    // (BUG-058 — inconsistent empty-state styling).
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: tokens.spacing.card + tokens.spacing.gap,
      ),
      child: FushiPlaceholderMessage(
        icon: DictionaryMediaType.instance.outlinedIcon,
        message: t.dictionaries_menu_empty,
      ),
    );
  }

  /// 词典列表的一行（M3 Expressive 卡片行，宽窄屏同一份）：
  /// - 行首：优先级序号徽标（多选态换成复选框）；
  /// - 中段：词典名（窄屏最多两行）+ 版本 / 状态；
  /// - 行尾：折叠三态一键切换（BUG-2158 状态一览）+ 启用开关。
  /// 改名 / 内容语言 / 更新 / 排序 / 删除这些低频动作收进详情（宽屏右侧侧板、
  /// 窄屏点行弹出底部 sheet），行尾不再堆八个无字图标。
  ///
  /// 整行可点：普通态打开详情，多选态切换勾选。键盘：Alt+↑/↓ 挪动、Delete 删除
  /// （见 [_handleRowKey]）；手柄 A 打开详情，排序按钮在详情里。
  Widget _buildDictionaryTile({
    required Dictionary dictionary,
    required DictionaryManagerRow row,
    required int index,
    required int count,
    required List<DictionaryManagerRow> rows,
    required bool split,
  }) {
    final bool enabled = _enabledInSection(dictionary);
    final ColorScheme scheme = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    final bool checked = _selectedNames.contains(dictionary.name);
    final bool showingDetail = split && _detailName == dictionary.name;
    final Text nameText = Text(
      // 用户可见的词典名一律走 effectiveDisplayName（改过名用改的，否则真名）。
      dictionary.effectiveDisplayName,
      style: textTheme.bodyLarge?.copyWith(
        color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
    final String baseSubtitle = _isKanjiPart(dictionary)
        ? '${_subtitleForDictionary(dictionary)} · ${t.dict_mixed_kanji_part}'
        : (_bothRevisionsLabel(row) ?? _subtitleForDictionary(dictionary));
    final Widget subtitle = _rowSubtitle(
      row,
      enabled ? baseSubtitle : '$baseSubtitle · ${t.dict_status_disabled}',
    );
    final Widget leading = _selecting
        ? FushiCheckbox(
            value: checked,
            onChanged: (_) => _toggleSelected(dictionary),
          )
        : DictionaryOrderBadge(position: index + 1, enabled: enabled);
    // 多选态行尾收起：整行就是勾选面，不再并排可单独操作的开关。
    final Widget? trailing = _selecting
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // 折叠管的是查词弹窗里这本的释义；汉字卡不折叠，「汉字」分区不给这个钮。
              if (_hasCollapseControl(dictionary))
                _buildDictionaryCollapseButton(dictionary),
              _buildDictionaryVisibilityButton(dictionary, enabled),
            ],
          );
    // 行内容本身不含拖拽监听：拖拽由外层 FushiReorderableColumn 统一接管
    // （鼠标按下即拖、触屏长按拖，局部坐标，缩放下零偏移）。行间距交给
    // FushiReorderableColumn 的 spacing（见 _buildDictionaryList），此处不再包
    // bottom padding——否则拖拽浮层会把行间空隙连同卡片一起涂成背景（BUG-078）。
    return Focus(
      focusNode: _rowFocusNode(dictionary.name),
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode node, KeyEvent event) =>
          _handleRowKey(event, row, index, rows),
      child: _buildDictionaryGroupCard(
        index: index,
        count: count,
        selected: checked || showingDetail,
        onTap: () =>
            _selecting ? _toggleSelected(dictionary) : _openRowDetail(row),
        child: FushiListItem(
          minHeight: 64,
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowHorizontal - tokens.spacing.gap / 2,
            vertical: tokens.spacing.rowVertical - tokens.spacing.gap / 2,
          ),
          leading: leading,
          title: nameText,
          // 窄屏给名字两行：长词典名（「三省堂国語辞典 第七版」）不再被截成
          // 五个字（TODO-749/751 的同一诉求，现在行尾只剩三件，宽度够）。
          titleMaxLines: compact ? 2 : 1,
          subtitle: subtitle,
          subtitleMaxLines: 1,
          trailing: trailing,
        ),
      ),
    );
  }

  /// 行副标题：有服务器词典时前面挂来源标签（本机 / 服务器 · 名字 / 两者 / 服务器上
  /// 已没有），没有服务器词典时与改造前一样只是一行文字。
  Widget _rowSubtitle(DictionaryManagerRow row, String text) {
    final ColorScheme scheme = theme.colorScheme;
    final Widget label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
    );
    if (!_hasServerRows) return label;
    final RemoteDictionary? remote = row.remote;
    final bool older = remote != null && _olderHost(remote.hostId);
    final bool showsChip = DictionarySourceChip.shows(
      row.source,
      olderHost: older,
    );
    return Row(
      children: <Widget>[
        DictionarySourceChip(
          key: ValueKey<String>('dict-row-source-${row.key}'),
          kind: row.source,
          hostName: _sourceHostName(row),
          showHostName: _lookupHostCount >= 2,
          olderHost: older,
        ),
        if (showsChip)
          SizedBox(width: FushiDesignTokens.of(context).spacing.gap / 2),
        Flexible(child: label),
      ],
    );
  }

  /// 「两者」行：服务器那份与本机这份版本不同时的副标题（「服务器版本 7，本机版本 6」）；
  /// 相同 / 任一边没有版本号时为 null（照常显示本机版本）。
  String? _bothRevisionsLabel(DictionaryManagerRow row) {
    final Dictionary? local = row.local;
    if (local == null || row.alsoOnHosts.isEmpty) return null;
    final List<RemoteDictionary> copies = _serverCopiesOf(local.name);
    if (copies.isEmpty) return null;
    final String server = copies.first.revision?.trim() ?? '';
    final String mine = _localRevision(local);
    if (server.isEmpty || mine.isEmpty || server == mine) return null;
    return t.dictionary_both_revisions(server: server, local: mine);
  }

  /// 只在服务器上的词典一行：与本机行同一外壳（序号徽标 / 名字 / 来源标签 / 开关），
  /// 开关写的是激活配置的 hidden（[AppModel.setRemoteDictionaryHidden]）。服务器上
  /// 已没有的行整行变淡，行尾多一个「忘掉」（确认后删掉它的目录行与设置）。多选态
  /// 不参与勾选：批量动作（删除文件等）对服务器词典没有意义。
  Widget _buildRemoteDictionaryTile({
    required DictionaryManagerRow row,
    required int index,
    required int count,
    required List<DictionaryManagerRow> rows,
    required bool split,
  }) {
    final RemoteDictionary remote = row.remote!;
    final bool enabled = !remote.hidden;
    final bool missing = remote.isMissing;
    final ColorScheme scheme = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    final bool showingDetail = split && _detailName == row.key;
    final String revision = remote.revision?.trim() ?? '';
    final String base = revision.isNotEmpty
        ? revision
        : _typeLabel(remote.type);
    final Widget? trailing = _selecting
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (missing)
                FushiIconButton(
                  key: ValueKey<String>('dict-row-forget-${row.key}'),
                  icon: FushiIcons.delete,
                  size: 20,
                  tooltip: t.dictionary_server_forget,
                  onTap: () => unawaited(_confirmForgetRemote(remote)),
                ),
              _buildRemoteVisibilityButton(row, enabled),
            ],
          );
    return Focus(
      focusNode: _rowFocusNode(row.key),
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (FocusNode node, KeyEvent event) =>
          _handleRowKey(event, row, index, rows),
      child: _buildDictionaryGroupCard(
        index: index,
        count: count,
        selected: showingDetail,
        onTap: () {
          if (!_selecting) _openRowDetail(row);
        },
        child: Opacity(
          opacity: missing ? 0.6 : 1,
          child: FushiListItem(
            minHeight: 64,
            padding: EdgeInsets.symmetric(
              horizontal: tokens.spacing.rowHorizontal - tokens.spacing.gap / 2,
              vertical: tokens.spacing.rowVertical - tokens.spacing.gap / 2,
            ),
            leading: DictionaryOrderBadge(
              position: index + 1,
              enabled: enabled && !missing,
              serverHostName: _hostName(remote.hostId),
            ),
            title: Text(
              row.displayName,
              style: textTheme.bodyLarge?.copyWith(
                color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            titleMaxLines: compact ? 2 : 1,
            subtitle: _rowSubtitle(
              row,
              enabled ? base : '$base · ${t.dict_status_disabled}',
            ),
            subtitleMaxLines: 1,
            trailing: trailing,
          ),
        ),
      ),
    );
  }

  Widget _buildRemoteVisibilityButton(DictionaryManagerRow row, bool enabled) {
    final String tooltip = enabled ? t.options_hide : t.options_show;
    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: enabled,
        label: tooltip,
        child: FushiSwitch(
          key: ValueKey<String>('dict-row-switch-${row.key}'),
          value: enabled,
          onChanged: (bool enabled) =>
              _setRemoteDictionaryEnabled(row.remote!, enabled),
        ),
      ),
    );
  }

  Future<bool> _setRemoteDictionaryEnabled(
    RemoteDictionary remote,
    bool enabled,
  ) => _saveDictionaryChange(
    () => appModel.setRemoteDictionaryHidden(remote, !enabled),
  );

  /// 「忘掉」一本服务器上已没有的词典：确认后删掉它的目录行与本端设置（排序 / 开关）。
  Future<void> _confirmForgetRemote(RemoteDictionary remote) async {
    final DictionaryManagerRow row = DictionaryManagerRow.remote(remote);
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.dictionary_server_forget_title(name: row.displayName),
      message: t.dictionary_server_forget_confirm(
        host: _hostName(remote.hostId),
      ),
      confirmLabel: t.dictionary_server_forget,
      cancelLabel: t.cancel,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    if (_detailName == row.key) _detailName = null;
    await _saveDictionaryChange(
      () => appModel.forgetRemoteDictionary(remote.hostId, remote.name),
    );
  }

  /// 词典列表的一行外壳：整张列表读作一个设置分组，而不是一摞各自独立的圆角卡
  /// （MD3 分段分组 / Apple inset grouped，见共享外壳 [FushiGroupedListItem]）。
  /// 行间距由 FushiReorderableColumn 的 spacing 统一插入（拖拽浮层不带缝），
  /// 外壳自己不加缝。可点卡片按下自带 FushiPressScale 下沉反馈。
  Widget _buildDictionaryGroupCard({
    required int index,
    required int count,
    required Widget child,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return FushiGroupedListItem(
      index: index,
      count: count,
      includeGap: false,
      selected: selected,
      onTap: onTap,
      child: child,
    );
  }

  Widget _buildDictionaryVisibilityButton(Dictionary dictionary, bool enabled) {
    final String tooltip = enabled ? t.options_hide : t.options_show;
    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: enabled,
        label: tooltip,
        child: FushiSwitch(
          key: ValueKey<String>('dict-row-switch-${dictionary.name}'),
          value: enabled,
          // 走开关自身的主题配色（MD3 primary 轨 / Apple 系统开关），
          // 不再自定 primaryContainer 浅色轨——那与全应用其它开关不是一个长相。
          onChanged: (bool enabled) =>
              _setDictionaryEnabled(dictionary, enabled),
        ),
      ),
    );
  }

  // TODO-091/TODO-381：每本词典的「折叠/展开」状态是行内的一键开关，20+ 本词典
  // 的折叠状态可在列表里一眼一览（图标本身即状态），单击直接切换、无需先开菜单。
  // 2026-10 词典管理重做：从行首挪到行尾开关旁（行首让给优先级序号 / 多选
  // 复选框），详情里另有同一状态的三段分段控件。折叠语义 = 查词弹窗里该词典
  // 释义默认折叠（见 dictionary_popup_webview 注入 collapsedDictionaryNames）；
  // 持久化仍走既有 Dictionary.collapsedLanguages（按阅读语言 JapaneseLanguage.
  // instance 区分），不改后端逻辑。
  // BUG-2158：这个按钮以前是双态的，而模型里只有一个 collapsedLanguages 名单 ——
  // 于是「不在名单里」被当成「展开」画出来，实际语义却是「继承全局」。全局
  // collapse_dictionaries 默认 true，用户对自动展开窗口之外的词典点「展开」，
  // 视觉上毫无反应。现在是三态循环：继承 → 显式展开 → 显式折叠 → 继承。
  //
  // 图标与 tooltip 都表示**当前态**（20+ 本词典要能一眼扫出谁被显式设过）。
  // 以前 tooltip 说的是「点一下会变成什么」，折叠图标配「跟随全局设置」被读成
  // 当前态。tooltip 带「默认展示」标题、用详情分段控件同一套状态词，免得中文
  // 「折叠」被读成动作。
  Widget _buildDictionaryCollapseButton(Dictionary dictionary) {
    final DictionaryCollapseState state = dictionary.collapseStateFor(
      JapaneseLanguage.instance,
    );
    final (IconData icon, String stateLabel) = switch (state) {
      // 未表态：一条横杠，与两个「已表态」图标一眼可分。点下去 → 显式展开。
      DictionaryCollapseState.inherit => (
        Icons.horizontal_rule,
        t.dict_collapse_state_inherit,
      ),
      // 显式展开：展开图标。点下去 → 显式折叠。
      DictionaryCollapseState.expanded => (
        Icons.unfold_more,
        t.dict_collapse_state_expanded,
      ),
      // 显式折叠：折叠图标。点下去 → 交还给全局。
      DictionaryCollapseState.collapsed => (
        Icons.unfold_less,
        t.dict_collapse_state_collapsed,
      ),
    };
    return FushiIconButton(
      key: ValueKey<String>('dict-row-collapse-${dictionary.name}'),
      icon: icon,
      size: 20,
      tooltip: t.dict_row_collapse_tooltip(state: stateLabel),
      onTap: () => _saveDictionaryChange(
        () => appModel.cycleDictionaryCollapseState(dictionary),
      ),
    );
  }

  // 用自实现的 FushiReorderableColumn（局部坐标长按拖拽），而非 SDK 的
  // ReorderableListView：后者的 Overlay 拖拽代理不认祖先 FushiAppUiScale 的
  // Transform.scale，缩放界面下长按拖拽反馈会按 (1−s)×距离 向右下漂移、飞离原位
  // （BUG-044）。前者把拖拽反馈渲染在列表自身坐标系、用 globalToLocal 消掉祖先缩放
  // → 任意缩放下都精确跟手、零偏移且视觉一致。键盘 Alt+↑/↓ 与详情里的
  // 上移 / 下移按钮（Icons.keyboard_arrow_up / Icons.keyboard_arrow_down）仍是
  // 无障碍 / 手柄重排路径。
  ///
  /// 一组语言一列：[dictionaries] 是该组词典（组内顺序），拖拽天然只能落在本组
  /// 之内；[groupKey] 让各组的列表 element 不因组数变化而错位复用；
  /// [entranceOffset] 是本组第一行在整屏错峰序列里的下标。
  Widget _buildDictionaryList(
    List<DictionaryManagerRow> rows, {
    required String? groupKey,
    required int entranceOffset,
  }) {
    final bool split = dictionaryManagerUsesSplitLayout(
      MediaQuery.sizeOf(context).width,
    );
    return FushiReorderableColumn(
      key: ValueKey<String>('dict-language-list-${groupKey ?? ''}'),
      itemCount: rows.length,
      // 行间距由列表统一插入（见 _buildDictionaryTile 不再自带 bottom padding）；
      // 圆角传卡片半径，让拖拽浮层裁成圆角、不在卡片四角露出底色。
      // 分组形态（见 _buildDictionaryGroupCard）：MD3 分段的 2px 缝，Apple
      // inset grouped 无缝（行间靠 separator）。
      spacing: fushiGroupedListGap(context),
      feedbackBorderRadius: fushiCardBorderRadius(context),
      keyForIndex: (int index) => ValueKey<String>(rows[index].key),
      // FushiReorderableColumn 的 to 已是最终下标，直接 removeAt(from)/insert(to)。
      onReorder: (int from, int to) => _reorderRows(from, to, rows),
      // 逐行错峰进场（窗口见 buildContent 的 FushiEntranceScope）：只改透明度与
      // 位移、不改布局，列表测高与拖拽浮层复制不受影响；拖拽浮层挂载时窗口早已
      // 关闭，浮层瞬间出现。服务器行与本机行同一条序列。
      itemBuilder: (BuildContext context, int index) {
        final DictionaryManagerRow row = rows[index];
        return FushiStaggeredEntrance(
          index: entranceOffset + index,
          child: row.isRemote
              ? _buildRemoteDictionaryTile(
                  row: row,
                  index: index,
                  count: rows.length,
                  rows: rows,
                  split: split,
                )
              : _buildDictionaryTile(
                  dictionary: row.local!,
                  row: row,
                  index: index,
                  count: rows.length,
                  rows: rows,
                  split: split,
                ),
        );
      },
    );
  }

  /// 把 [displayed] 中 `oldIndex` 处的行移动到**最终下标** `newIndex`，重排 order
  /// 并持久化。`newIndex` 是移动完成后该行应处的位置（非 SDK 的「插入前下标」），
  /// 拖拽、键盘、详情里的上移 / 下移 / 置顶 / 置底统一走这套最终下标语义——无需
  /// SDK 的 `if(new>old)new--` 特例。越界与原地不动直接忽略。
  ///
  /// [displayed] 是**屏幕上的一个语言组**（来源筛选后可能只是组的一部分），只用来
  /// 取被移动的是哪行：组成员一律从最新分区现算——列表是渲染时捕获的，期间别处
  /// （ctl 路由、导入、改语言、目录刷新）可能已经改了组成员。筛选生效时落点换算成
  /// 完整组里「目标行」的下标，筛选后挪一格 = 越过屏幕上相邻的那一行。
  ///
  /// 分区里没有服务器行时走原路径（[moveDictionaryWithinLanguageGroup]）逐字不变；
  /// 有服务器行时整个分区按混排顺序 0..n-1 重编号，本机与服务器两张表同一事务落库
  /// （[AppModel.updateMixedDictionaryOrder]），管理页显示的顺序就是真实查词顺序。
  Future<bool> _reorderRows(
    int oldIndex,
    int newIndex,
    List<DictionaryManagerRow> displayed,
  ) async {
    if (oldIndex < 0 || oldIndex >= displayed.length) return false;
    final DictionaryManagerRow moved = displayed[oldIndex];
    final List<DictionaryManagerRow> section = _rowsForType(_selectedType);
    // 不筛选时屏幕上的组就是完整组：落点直接是组内下标（组成员变了也按最新组算）。
    // 筛选后屏幕上只是组的一部分，落点换算成完整组里「目标行」的下标。
    int target = newIndex;
    if (_effectiveSourceFilter != DictionarySourceFilter.all) {
      final DictionaryManagerRow anchor =
          displayed[newIndex.clamp(0, displayed.length - 1)];
      target = dictionaryManagerLanguageGroupOf(
        section,
        moved,
      ).indexWhere((DictionaryManagerRow r) => r.key == anchor.key);
      if (target < 0) return false;
    }

    if (!section.any((DictionaryManagerRow r) => r.isRemote)) {
      final List<Dictionary>? cloneDictionaries =
          moveDictionaryWithinLanguageGroup(
            _dictionariesForType(_selectedType),
            moved.key,
            target,
          );
      if (cloneDictionaries == null) return false;

      // 「汉字」分区里混合词典只动汉字部分的位置，不能走按 order 整体重编号的路径
      // （那会把它在「术语」分区的位置一起改掉）。
      if (_selectedType == DictionaryType.kanji) {
        return _saveDictionaryChange(
          () => appModel.updateKanjiSectionOrder(cloneDictionaries),
        );
      }

      for (int i = 0; i < cloneDictionaries.length; i++) {
        cloneDictionaries[i] = cloneDictionaries[i].copyWith(order: i);
      }

      return _saveDictionaryChange(
        () => appModel.updateDictionaryOrder(cloneDictionaries),
      );
    }

    final List<DictionaryManagerRow>? next =
        moveDictionaryManagerRowWithinLanguageGroup(section, moved.key, target);
    if (next == null) return false;
    final List<Dictionary> locals = <Dictionary>[];
    final List<RemoteDictionary> remotes = <RemoteDictionary>[];
    for (int i = 0; i < next.length; i++) {
      final DictionaryManagerRow row = next[i];
      final Dictionary? local = row.local;
      if (local != null) {
        locals.add(local.copyWith(order: i));
      } else {
        remotes.add(row.remote!.copyWith(order: i));
      }
    }
    return _saveDictionaryChange(
      () => appModel.updateMixedDictionaryOrder(locals, remotes),
    );
  }

  /// 把 [row] 挪到它所在语言组的最终下标 [to]（详情里的四个排序按钮）。
  Future<bool> _moveRowTo(DictionaryManagerRow row, int to) async {
    final List<DictionaryManagerRow> group = _languageGroupRowsOf(row);
    final int from = group.indexWhere(
      (DictionaryManagerRow r) => r.key == row.key,
    );
    if (from < 0) return false;
    return _reorderRows(from, to, group);
  }

  /// 「移到第几位」：弹位置输入框，确认后走与拖动 / 上下移同一条
  /// [_reorderRows] 写入路径，焦点跟着被移动的词典走（列表所在路由是
  /// 当前路由时——窄屏从底部 sheet 里移动时焦点留在 sheet，sheet 内容自己刷新）。
  Future<void> _promptMoveRow(DictionaryManagerRow row) async {
    final List<DictionaryManagerRow> group = _languageGroupRowsOf(row);
    final int from = group.indexWhere(
      (DictionaryManagerRow r) => r.key == row.key,
    );
    if (from < 0 || group.length < 2) return;
    final int? to = await showDictionaryPositionDialog(
      context: context,
      name: row.displayName,
      position: from,
      count: group.length,
    );
    if (!mounted || to == null) return;
    if (await _moveRowTo(row, to)) {
      _focusRowAfterFrame(row.key);
    }
  }

  FocusNode _rowFocusNode(String name) => _rowFocusNodes.putIfAbsent(
    name,
    () => FocusNode(debugLabel: 'dict-row-$name'),
  );

  /// 行级键盘：Alt+↑/↓ 上下挪一位（焦点跟着词典走），Delete 删除这本。只在行内
  /// 某个控件持焦时生效；其余键照常冒泡给全局方向导航。
  KeyEventResult _handleRowKey(
    KeyEvent event,
    DictionaryManagerRow row,
    int index,
    List<DictionaryManagerRow> rows,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final bool alt = HardwareKeyboard.instance.isAltPressed;
    final LogicalKeyboardKey key = event.logicalKey;
    if (alt &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      final int to = key == LogicalKeyboardKey.arrowUp ? index - 1 : index + 1;
      if (to >= 0 && to < rows.length) {
        unawaited(
          _reorderRows(index, to, rows).then((bool saved) {
            if (saved) _focusRowAfterFrame(row.key);
          }),
        );
      }
      return KeyEventResult.handled;
    }
    // Delete 删的是本机词典的文件；服务器词典没有本机文件，不响应。
    final Dictionary? local = row.local;
    if (!alt &&
        event is KeyDownEvent &&
        key == LogicalKeyboardKey.delete &&
        !_selecting &&
        local != null) {
      unawaited(showDictionaryDeleteDialog(local));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 重排后把焦点交给挪到新位置的那一行（它的第一个可聚焦控件 = 整行点击面）。
  void _focusRowAfterFrame(String name) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 上面还压着 sheet / 对话框时不越级抢焦点（那会把键盘从覆盖层里拽走）。
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      final FocusNode? row = _rowFocusNodes[name];
      if (row == null) return;
      // 逐层（广度优先）找最浅的可聚焦节点——整行点击面，而不是行尾的开关 /
      // 折叠按钮（descendants 是后序，最深的先出，不能直接取第一个）。
      Iterable<FocusNode> level = row.children;
      while (level.isNotEmpty) {
        for (final FocusNode node in level) {
          if (node.canRequestFocus && !node.skipTraversal) {
            node.requestFocus();
            return;
          }
        }
        level = level.expand((FocusNode node) => node.children).toList();
      }
    });
    // addPostFrameCallback 不调度帧（树静止时回调永不触发），显式要一帧。
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // ── 详情：宽屏右侧侧板 / 窄屏底部 sheet ─────────────────────────────────

  /// 点一行：宽屏把它放进右侧详情侧板（再点一次收回概览），窄屏弹底部 sheet。
  void _openRowDetail(DictionaryManagerRow row) {
    if (dictionaryManagerUsesSplitLayout(MediaQuery.sizeOf(context).width)) {
      setState(() {
        _detailName = _detailName == row.key ? null : row.key;
      });
      return;
    }
    final Dictionary? local = row.local;
    unawaited(
      local != null
          ? _showDictionaryDetailSheet(local)
          : _showRemoteDictionaryDetailSheet(row.key),
    );
  }

  Future<void> _showRemoteDictionaryDetailSheet(String key) {
    return adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return ValueListenableBuilder<int>(
          valueListenable: _revision,
          builder: (BuildContext context, int _, Widget? __) {
            final RemoteDictionary? current = _findRemote(key);
            if (current == null) return const SizedBox.shrink();
            final FushiDesignTokens tokens = FushiDesignTokens.of(context);
            return FushiModalSheetFrame(
              title: DictionaryManagerRow.remote(current).displayName,
              subtitle: _typeLabel(current.type),
              leadingIcon: FushiIcons.server,
              scrollable: true,
              maxHeightFactor: 0.9,
              bodyPadding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                0,
                tokens.spacing.page,
                tokens.spacing.page,
              ),
              body: _buildRemoteDictionaryDetail(
                current,
                showHeader: false,
                // 忘掉之后这本已不存在：先收 sheet 再走确认。
                beforeForget: () => Navigator.of(sheetContext).pop(),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildRemoteDictionaryDetail(
    RemoteDictionary remote, {
    required bool showHeader,
    VoidCallback? beforeForget,
  }) {
    final DictionaryManagerRow row = DictionaryManagerRow.remote(remote);
    final List<DictionaryManagerRow> siblings = _languageGroupRowsOf(row);
    final int position = siblings.indexWhere(
      (DictionaryManagerRow r) => r.key == row.key,
    );
    return RemoteDictionaryDetail(
      key: ValueKey<String>('dict-detail-${row.key}'),
      row: row,
      hostName: _hostName(remote.hostId),
      enabled: !remote.hidden,
      typeLabel: _typeLabel(remote.type),
      lastSeenLabel: dictionaryManagerTimestampLabel(remote.lastSeenAt),
      languageLabel: _languageLabel(source: remote.sourceLanguage),
      onRename: () => unawaited(_renameRemoteDictionary(remote)),
      olderHost: _olderHost(remote.hostId),
      // 别的 host 上同名、被这一行遮住的那几份（列表只列排得最前的一份）。
      shadowedOnHosts: <String>[
        for (final RemoteDictionary other in _serverCopiesOf(remote.name))
          if (other.hostId != remote.hostId) _hostName(other.hostId),
      ],
      position: position < 0 ? 0 : position,
      count: siblings.length,
      showHeader: showHeader,
      onEnabledChanged: (bool enabled) =>
          _setRemoteDictionaryEnabled(remote, enabled),
      onMoveTo: (int to) => _moveRowTo(row, to),
      onMoveToPrompt: () => _promptMoveRow(row),
      onForget: remote.isMissing
          ? () {
              beforeForget?.call();
              unawaited(_confirmForgetRemote(remote));
            }
          : null,
      // 服务器上还在、本机没有同名（服务器行的定义）才给下载；弹窗进程没有传输服务。
      onDownload: remote.isMissing || appModel.dictionaryTransferService == null
          ? null
          : () => unawaited(_downloadDictionaryFromHost(remote)),
    );
  }

  /// 本机词典可以推去的 host：候选 host 里目录上还没有同名词典（没缺席）的那些，
  /// 按配对列表顺序。已有的就是「两者」行，不给推送。
  Map<String, String> _pushTargetsFor(Dictionary dictionary) {
    if (appModel.dictionaryTransferService == null) {
      return const <String, String>{};
    }
    final Set<String> hasIt = <String>{
      for (final RemoteDictionary r in _serverCopiesOf(dictionary.name))
        r.hostId,
    };
    return <String, String>{
      for (final String id in _hostNames.keys)
        if (_pushHostIds.contains(id) && !hasIt.contains(id)) id: _hostName(id),
    };
  }

  Future<void> _pushDictionaryToHost(Dictionary dictionary, String hostId) =>
      _runDictionaryTransfer(
        push: true,
        hostId: hostId,
        name: dictionary.name,
        displayName: dictionary.effectiveDisplayName,
      );

  Future<void> _downloadDictionaryFromHost(RemoteDictionary remote) =>
      _runDictionaryTransfer(
        push: false,
        hostId: remote.hostId,
        name: remote.name,
        displayName: remote.effectiveDisplayName,
      );

  /// 按 host 推送 / 下载一本词典：任务挂在与下载 / 更新同一个
  /// [DictionaryDownloadController] 上（同一把词典写侧互斥、同一个进度框与回程条、
  /// 结局由 controller 统一 toast）。传输本身走 [DictionaryTransferService]（同步锁 +
  /// 只连这一台 host 的互联后端），dio 取消令牌够不着它，所以一开始就切到不可取消
  /// 的阶段，不给一个按了没反应的取消钮。
  Future<void> _runDictionaryTransfer({
    required bool push,
    required String hostId,
    required String name,
    required String displayName,
  }) async {
    final DictionaryTransferService? service =
        appModel.dictionaryTransferService;
    if (service == null) return;
    final String host = _hostName(hostId);
    await _runWithDownloadProgressDialog(
      initialMessage: push
          ? t.dict_transfer_pushing(name: displayName, host: host)
          : t.dict_downloading(name: displayName),
      body: (DictionaryDownloadJob job) async {
        job.markImportPhase();
        void onProgress(DictionaryTransferProgress progress) {
          if (progress.stage == DictionaryTransferStage.importing) {
            enterDictionaryImportStage(
              name: displayName,
              progressNotifier: job.message,
              downloadProgress: job.progress,
              job: job,
            );
            return;
          }
          job.progress.value = progress.fraction ?? 0;
        }

        final DictionaryTransferResult result = push
            ? await service.pushToHost(hostId, name, onProgress: onProgress)
            : await service.downloadFromHost(
                hostId,
                name,
                onProgress: onProgress,
              );
        return _dictionaryTransferOutcome(
          result,
          push: push,
          name: displayName,
          host: host,
        );
      },
    );
    await _loadServerSources();
  }

  DictionaryDownloadOutcome _dictionaryTransferOutcome(
    DictionaryTransferResult result, {
    required bool push,
    required String name,
    required String host,
  }) {
    switch (result) {
      case DictionaryTransferDone():
        return DictionaryDownloadOutcome(
          message: push
              ? t.dict_transfer_push_done(name: name, host: host)
              : t.dict_transfer_download_done(name: name),
          severity: ToastSeverity.success,
        );
      case DictionaryTransferAlreadyPresent():
        return DictionaryDownloadOutcome(
          message: push
              ? t.dict_transfer_already_on_host(name: name, host: host)
              : t.dict_transfer_already_installed(name: name),
          severity: ToastSeverity.info,
        );
      case DictionaryTransferFailed(:final DictionaryTransferFailureKind kind):
        if (kind == DictionaryTransferFailureKind.failed) {
          ErrorLogService.instance.log(
            'DictionaryDialog.transfer',
            result.error ?? 'unknown',
            StackTrace.current,
          );
        }
        return DictionaryDownloadOutcome(
          message: switch (kind) {
            DictionaryTransferFailureKind.notPaired =>
              t.dict_transfer_error_not_paired(host: host),
            DictionaryTransferFailureKind.unreachable =>
              t.dict_transfer_error_unreachable(host: host),
            DictionaryTransferFailureKind.unauthorized =>
              t.dict_transfer_error_unauthorized(host: host),
            DictionaryTransferFailureKind.notFound =>
              t.dict_transfer_error_not_found(name: name),
            DictionaryTransferFailureKind.outOfDisk =>
              t.dict_transfer_error_out_of_disk,
            DictionaryTransferFailureKind.busy => t.dict_transfer_error_busy,
            DictionaryTransferFailureKind.failed =>
              t.dict_transfer_error_failed(error: '${result.error}'),
          },
          severity: kind == DictionaryTransferFailureKind.busy
              ? ToastSeverity.info
              : ToastSeverity.error,
          toastLength: Toast.LENGTH_LONG,
        );
    }
  }

  /// 服务器词典的本机显示名：与本机词典同一个改名对话框，写设备本地的
  /// `remote_dictionary_metadata.local_display_name`（不进配置、不导出）。
  Future<void> _renameRemoteDictionary(RemoteDictionary remote) async {
    final String current = remote.effectiveDisplayName;
    final String? name = await showNameInputDialog(
      context: context,
      title: t.dict_rename,
      labelText: t.dict_rename_label,
      initialName: current,
      leadingIcon: FushiIcons.rename,
    );
    if (!mounted || name == null || name == current) return;
    await _saveDictionaryChange(
      () => appModel.setRemoteDictionaryLocalDisplayName(remote, name),
    );
  }

  /// 「两者」行详情里服务器那一份：所在 host、服务器版本、本机版本（设计稿 6）。
  Widget? _buildServerCopySection(Dictionary dictionary) {
    final List<RemoteDictionary> copies = _serverCopiesOf(dictionary.name);
    if (copies.isEmpty) return null;
    final RemoteDictionary copy = copies.first;
    final String serverRevision = copy.revision?.trim() ?? '';
    final String localRevision = _localRevision(dictionary);
    final ColorScheme scheme = theme.colorScheme;
    Widget info(String label, String value) => AdaptiveSettingsRow(
      title: label,
      trailingFlexible: true,
      trailing: Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.end,
        style: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
    return AdaptiveSettingsSection(
      key: ValueKey<String>('dict-detail-server-copy-${dictionary.name}'),
      title: t.dictionary_detail_server_copy_section,
      children: <Widget>[
        info(
          t.dictionary_detail_host_label,
          copies.map((RemoteDictionary r) => _hostName(r.hostId)).join(', '),
        ),
        info(
          t.dictionary_detail_server_revision_label,
          serverRevision.isEmpty ? '—' : serverRevision,
        ),
        info(
          t.dictionary_detail_local_revision_label,
          localRevision.isEmpty ? '—' : localRevision,
        ),
      ],
    );
  }

  Future<void> _showDictionaryDetailSheet(Dictionary dictionary) {
    return adaptiveModalSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return ValueListenableBuilder<int>(
          valueListenable: _revision,
          builder: (BuildContext context, int _, Widget? __) {
            final Dictionary? current = _findDictionary(dictionary.name);
            if (current == null) return const SizedBox.shrink();
            final FushiDesignTokens tokens = FushiDesignTokens.of(context);
            return FushiModalSheetFrame(
              title: current.effectiveDisplayName,
              subtitle: _sectionTypeLabel(current),
              leadingIcon: DictionaryMediaType.instance.outlinedIcon,
              scrollable: true,
              maxHeightFactor: 0.9,
              bodyPadding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                0,
                tokens.spacing.page,
                tokens.spacing.page,
              ),
              body: _buildDictionaryDetail(
                current,
                showHeader: false,
                onDeleteRequested: () {
                  // 先收 sheet 再走删除确认：删完这本已不存在，sheet 留着只会
                  // 变成空壳。
                  Navigator.of(sheetContext).pop();
                  unawaited(showDictionaryDeleteDialog(current));
                },
              ),
            );
          },
        );
      },
    );
  }

  Dictionary? _findDictionary(String name) {
    for (final Dictionary d in appModel.dictionaries) {
      if (d.name == name) return d;
    }
    return null;
  }

  Widget _buildDictionaryDetail(
    Dictionary dictionary, {
    required bool showHeader,
    required VoidCallback onDeleteRequested,
  }) {
    // 位置与「共几本」都按语言组算：排序只在组内进行（服务器行一并计入）。
    final DictionaryManagerRow row = DictionaryManagerRow.local(dictionary);
    final List<DictionaryManagerRow> siblings = _languageGroupRowsOf(row);
    final int position = siblings.indexWhere(
      (DictionaryManagerRow r) => r.key == row.key,
    );
    final DictionaryFormat? format =
        appModel.dictionaryFormats[dictionary.formatKey];
    final String languageLabel = _languageLabel(
      override: dictionary.languageOverride,
      source: dictionary.sourceLanguage,
    );
    final List<RemoteDictionary> serverCopies = _serverCopiesOf(
      dictionary.name,
    );
    return DictionaryManagerDetail(
      key: ValueKey<String>('dict-detail-${dictionary.name}'),
      dictionary: dictionary,
      enabled: _enabledInSection(dictionary),
      collapseState: dictionary.collapseStateFor(JapaneseLanguage.instance),
      typeLabel: _sectionTypeLabel(dictionary),
      versionLabel: dictionary.revision,
      formatLabel: format?.name ?? dictionary.formatKey,
      languageLabel: languageLabel,
      position: position < 0 ? 0 : position,
      count: siblings.length,
      showHeader: showHeader,
      onEnabledChanged: (bool enabled) =>
          _setDictionaryEnabled(dictionary, enabled),
      onCollapseChanged: _hasCollapseControl(dictionary)
          ? (DictionaryCollapseState state) =>
                _setCollapseState(dictionary, state)
          : null,
      onRename: () => _renameDictionary(dictionary),
      onLanguage: () => _showDictionaryLanguageDialog(dictionary),
      // TODO-839：每本词典都给「更新」（消除「这本能更新那本不能」的断层），按
      // isUpdatable 分流：在线来源走 _updateSingleDictionary（拉远端 index.json
      // 比 revision），本地导入 / 旧词典走 _updateDictionaryFromFile（选文件
      // force 覆盖，异名先确认）。
      onUpdate: () => dictionary.isUpdatable
          ? _updateSingleDictionary(dictionary)
          : _updateDictionaryFromFile(dictionary),
      onMoveTo: (int to) => _moveRowTo(row, to),
      onMoveToPrompt: () => _promptMoveRow(row),
      onDelete: onDeleteRequested,
      // 「两者」行：标题下挂来源 chip，详情多一组服务器那份的信息（host + 两边版本）。
      headerTags: serverCopies.isEmpty
          ? const <Widget>[]
          : <Widget>[
              DictionarySourceChip(
                kind: DictionarySourceKind.both,
                hostName: serverCopies
                    .map((RemoteDictionary r) => _hostName(r.hostId))
                    .join(', '),
              ),
            ],
      serverCopySection: _buildServerCopySection(dictionary),
      transferSection: _buildTransferSection(dictionary),
    );
  }

  /// 「推送到 <服务器>」分组；没有还缺这本的查词 host 时不画。
  Widget? _buildTransferSection(Dictionary dictionary) {
    final Map<String, String> targets = _pushTargetsFor(dictionary);
    if (targets.isEmpty) return null;
    return DictionaryTransferSection(
      key: ValueKey<String>('dict-detail-transfer-${dictionary.name}'),
      dictionaryName: dictionary.name,
      hosts: targets,
      onPush: (String hostId) =>
          unawaited(_pushDictionaryToHost(dictionary, hostId)),
    );
  }

  /// 分段选择提交一个目标态；循环多次会在异步写入期间与后续选择交错。
  /// 行内循环按钮与此入口在 repository 复用同一三态写入规则。
  Future<bool> _setCollapseState(
    Dictionary dictionary,
    DictionaryCollapseState target,
  ) => _saveDictionaryChange(
    () => appModel.setDictionaryCollapseState(dictionary, target),
  );

  /// 宽屏右侧侧板：选中了词典 = 它的详情；没选 = 概览（四类计数 + 自动更新）。
  /// 切换时淡入 + 轻微上移（时长取 FushiMotion，减弱动态效果下归零）。
  Widget _buildDetailPane() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 只认此刻列表里看得见的行（当前分区 + 当前来源筛选）：换分区 / 换筛选 / 那本被
    // 筛掉时侧板回到概览，不停在一本看不见的词典上。
    final String? detailKey =
        _detailName != null &&
            _visibleRows().any((DictionaryManagerRow r) => r.key == _detailName)
        ? _detailName
        : null;
    final RemoteDictionary? remote = detailKey == null
        ? null
        : _findRemote(detailKey);
    final Dictionary? dictionary = detailKey == null || remote != null
        ? null
        : _findDictionary(detailKey);
    final List<RemoteDictionary> serverOnly = _serverOnlyDictionaries();
    final Widget content;
    if (remote != null) {
      content = _buildRemoteDictionaryDetail(remote, showHeader: true);
    } else if (dictionary != null) {
      content = _buildDictionaryDetail(
        dictionary,
        showHeader: true,
        onDeleteRequested: () => showDictionaryDeleteDialog(dictionary),
      );
    } else {
      content = DictionaryManagerOverview(
        key: const ValueKey<String>('dict-overview'),
        counts: _typeCounts(),
        // 总数 = 本机词典 + 只在服务器上的词典（与列表里的行一一对应）。
        totalDictionaries: appModel.dictionaries.length + serverOnly.length,
        enabledDictionaries:
            appModel.dictionaries
                .where((Dictionary d) => !d.isHidden(JapaneseLanguage.instance))
                .length +
            serverOnly.where((RemoteDictionary r) => !r.hidden).length,
        selectedType: _selectedType,
        onTypeSelected: _selectType,
        footer: _buildAutoUpdateCard(),
      );
    }
    return AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.medium),
      switchInCurve: FushiMotion.enter,
      switchOutCurve: FushiMotion.exit,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.02),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
      child: ListView(
        key: ValueKey<String?>(
          remote != null || dictionary != null ? detailKey : null,
        ),
        padding: EdgeInsets.all(tokens.spacing.page),
        children: <Widget>[content],
      ),
    );
  }

  List<DictionaryTypeCount> _typeCounts() {
    DictionaryTypeCount count(DictionaryType type, IconData icon) {
      final List<Dictionary> list = _dictionariesForType(type);
      final List<RemoteDictionary> serverOnly = <RemoteDictionary>[
        for (final DictionaryManagerRow row in _rowsForType(type))
          if (row.remote != null) row.remote!,
      ];
      return DictionaryTypeCount(
        type: type,
        label: _typeLabel(type),
        icon: icon,
        total: list.length + serverOnly.length,
        enabled:
            list
                .where(
                  (Dictionary d) => type == DictionaryType.kanji
                      ? d.isKanjiSectionEnabled(JapaneseLanguage.instance)
                      : !d.isHidden(JapaneseLanguage.instance),
                )
                .length +
            serverOnly.where((RemoteDictionary r) => !r.hidden).length,
        onServer: serverOnly.length,
        unlistedOnServer: _unlistedServerCount(type),
      );
    }

    return <DictionaryTypeCount>[
      count(DictionaryType.term, Icons.menu_book_outlined),
      count(DictionaryType.kanji, Icons.translate),
      count(DictionaryType.frequency, Icons.bar_chart),
      count(DictionaryType.pitch, Icons.graphic_eq),
    ];
  }

  String _typeLabel(DictionaryType type) {
    return switch (type) {
      DictionaryType.term => t.dictionary_type_term,
      DictionaryType.kanji => t.dictionary_section_kanji,
      DictionaryType.frequency => t.dictionary_type_frequency,
      DictionaryType.pitch => t.dictionary_type_pitch,
    };
  }

  // ── 多选 / 批量 ─────────────────────────────────────────────────────────

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selectedNames.clear();
    });
  }

  void _toggleSelected(Dictionary dictionary) {
    setState(() {
      if (!_selectedNames.remove(dictionary.name)) {
        _selectedNames.add(dictionary.name);
      }
    });
  }

  List<Dictionary> get _selectedDictionaries => _dictionariesForType(
    _selectedType,
  ).where((Dictionary d) => _selectedNames.contains(d.name)).toList();

  /// 多选态的底部批量栏（共享 [BatchActionBar]：已选 N · 全选 · 反选 + 动作）。
  /// 全选 / 反选的域是当前类型的可见列表。非多选态返回 null（不占位）。
  Widget? _buildBatchBar() {
    if (!_selecting) return null;
    final List<Dictionary> visible = _dictionariesForType(_selectedType);
    final bool any = _selectedNames.isNotEmpty;
    final bool compact = MediaQuery.sizeOf(context).width < 480;
    // 只选了一本时可「移到第几位」（多本没有单一目标位置，置灰）。
    final List<Dictionary> picked = _selectedDictionaries;
    final Widget moveTo = FushiIconButton(
      key: const ValueKey<String>('dict-batch-move-to'),
      icon: Icons.format_list_numbered,
      tooltip: t.dict_order_position_move,
      enabled:
          picked.length == 1 &&
          _languageGroupRowsOf(
                DictionaryManagerRow.local(picked.single),
              ).length >
              1,
      onTap: () => _promptMoveRow(DictionaryManagerRow.local(picked.single)),
    );
    final Widget delete = FushiIconButton(
      key: const ValueKey<String>('dict-batch-delete'),
      icon: Icons.delete_outline,
      tooltip: t.options_delete,
      enabled: any,
      enabledColor: fushiStatusColor(context, FushiStatusTone.error),
      onTap: _batchDelete,
    );
    return BatchActionBar(
      key: const ValueKey<String>('dict-batch-bar'),
      selectedCount: _selectedNames.length,
      onSelectAll: () => setState(
        () => _selectedNames.addAll(visible.map((Dictionary d) => d.name)),
      ),
      onInvertSelection: () => setState(() {
        final Set<String> next = <String>{
          for (final Dictionary d in visible)
            if (!_selectedNames.contains(d.name)) d.name,
        };
        _selectedNames
          ..clear()
          ..addAll(next);
      }),
      // 窄屏只放图标（带 tooltip），宽屏图标 + 文字；退出多选在页头的多选开关。
      actions: compact
          ? <Widget>[
              FushiIconButton(
                key: const ValueKey<String>('dict-batch-enable'),
                icon: Icons.visibility_outlined,
                tooltip: t.dict_batch_enable,
                enabled: any,
                onTap: () => _batchSetEnabled(true),
              ),
              FushiIconButton(
                key: const ValueKey<String>('dict-batch-disable'),
                icon: Icons.visibility_off_outlined,
                tooltip: t.dict_batch_disable,
                enabled: any,
                onTap: () => _batchSetEnabled(false),
              ),
              moveTo,
              delete,
            ]
          : <Widget>[
              FushiTextButton.icon(
                key: const ValueKey<String>('dict-batch-enable'),
                onPressed: any ? () => _batchSetEnabled(true) : null,
                icon: const FushiIcon(Icons.visibility_outlined, size: 18),
                label: Text(t.dict_batch_enable),
              ),
              FushiTextButton.icon(
                key: const ValueKey<String>('dict-batch-disable'),
                onPressed: any ? () => _batchSetEnabled(false) : null,
                icon: const FushiIcon(Icons.visibility_off_outlined, size: 18),
                label: Text(t.dict_batch_disable),
              ),
              moveTo,
              delete,
            ],
    );
  }

  /// 批量启用 / 停用提交目标值，同一动作重复点击仍保持幂等。
  Future<bool> _batchSetEnabled(bool enabled) =>
      _saveDictionaryChange(() async {
        for (final Dictionary dictionary in _selectedDictionaries) {
          await _writeEnabledInSection(dictionary, enabled);
        }
      });

  /// 删除确认正文。「汉字」分区里的混合词典行只是整本词典的汉字部分，删除却是
  /// 整本删（术语词条一起没了），确认框必须说清楚并指向只关汉字部分的开关。
  String _deleteConfirmContent(List<Dictionary> targets) =>
      targets.any(_isKanjiPart)
      ? '${t.dialog_content_dictionary_delete}\n\n'
            '${t.dict_mixed_kanji_part_delete_note}'
      : t.dialog_content_dictionary_delete;

  /// 批量删除：一次确认，逐本走与单本删除同一条 [AppModel.deleteDictionary]
  /// （同一进度页 / 失败提示），删完退出多选。
  Future<void> _batchDelete() {
    final List<Dictionary> targets = _selectedDictionaries;
    if (targets.isEmpty) return Future<void>.value();
    return _showDictionaryActionConfirmDialog(
      title: t.dict_batch_delete_title(n: targets.length),
      content: _deleteConfirmContent(targets),
      confirmLabel: t.dialog_delete,
      run: () async {
        for (final Dictionary dictionary in targets) {
          await appModel.deleteDictionary(dictionary);
        }
        _selectedNames.clear();
        _selecting = false;
        if (targets.any((Dictionary d) => d.name == _detailName)) {
          _detailName = null;
        }
      },
    );
  }

  /// 行副标题：版本号（revision / version / formatVersion），没有就退回格式名。
  String _subtitleForDictionary(Dictionary dictionary) {
    final DictionaryFormat? dictionaryFormat =
        appModel.dictionaryFormats[dictionary.formatKey];
    final String revision =
        dictionary.metadata['revision'] ??
        dictionary.metadata['version'] ??
        dictionary.metadata['formatVersion'] ??
        '';
    if (revision.isNotEmpty) return revision;
    return dictionaryFormat?.name ?? dictionary.formatKey;
  }

  List<Dictionary> _dictionariesForType(DictionaryType type) {
    return switch (type) {
      DictionaryType.term => appModel.termDictionaries,
      DictionaryType.kanji => appModel.kanjiSectionDictionaries,
      DictionaryType.frequency => appModel.freqDictionaries,
      DictionaryType.pitch => appModel.pitchDictionaries,
    };
  }

  /// 当前在「汉字」分区里看的是一本混合词典的汉字部分（Hoshi Reader 同款：附汉字
  /// 表的 term 词典在「术语」「汉字」两个分区各占一行，开关与排序各管各的）。
  bool _isKanjiPart(Dictionary dictionary) =>
      _selectedType == DictionaryType.kanji && dictionary.hasEmbeddedKanji;

  /// 这一行所在的分区：汉字部分算「汉字」，其余按词典自身类型。
  DictionaryType _sectionTypeOf(Dictionary dictionary) =>
      _isKanjiPart(dictionary) ? DictionaryType.kanji : dictionary.type;

  /// 这一行给不给「折叠」控件（行内按钮与详情里的分段同一判据）：折叠只作用于查词
  /// 弹窗里的释义，「汉字」分区的行对应汉字卡（不折叠），在那里给控件改的会是混合
  /// 词典术语部分的状态。
  bool _hasCollapseControl(Dictionary dictionary) =>
      _sectionTypeOf(dictionary) != DictionaryType.kanji;

  String _sectionTypeLabel(Dictionary dictionary) => _isKanjiPart(dictionary)
      ? '${_typeLabel(DictionaryType.kanji)} · ${t.dict_mixed_kanji_part}'
      : _typeLabel(dictionary.type);

  bool _enabledInSection(Dictionary dictionary) => _isKanjiPart(dictionary)
      ? !dictionary.isKanjiPartHidden
      : !dictionary.isHidden(JapaneseLanguage.instance);

  Future<void> _writeEnabledInSection(
    Dictionary dictionary,
    bool enabled,
  ) async {
    if (_isKanjiPart(dictionary)) {
      await appModel.setDictionaryKanjiPartHidden(dictionary, !enabled);
      return;
    }
    await appModel.setDictionaryHidden(dictionary, !enabled);
    // 「两者」行只有一个开关：服务器上同名的目录行跟着走，否则删掉本机那份之后
    // 目录行会带着旧开关冒出来（推送时关着，之后打开了，回来还是关的）。各 host 都跟，
    // 含没开「用于查词」的——它们不在 remoteDictionaries 里，但那台 host 重新打开查词
    // 时同样会带着旧开关出现。
    await appModel.setCatalogRowsHiddenNamed(dictionary.name, !enabled);
  }

  String _labelForType(DictionaryType type) {
    return switch (type) {
      DictionaryType.term => t.dictionary_section_term,
      DictionaryType.kanji => t.dictionary_section_kanji,
      DictionaryType.frequency => t.dictionary_section_frequency,
      DictionaryType.pitch => t.dictionary_section_pitch,
    };
  }

  Future<bool> _setDictionaryEnabled(Dictionary dictionary, bool enabled) =>
      _saveDictionaryChange(() => _writeEnabledInSection(dictionary, enabled));

  FushiPopupMenuItem<VoidCallback> buildPopupItem({
    required String label,
    required VoidCallback action,
    IconData? icon,
    Color? color,
  }) {
    return FushiPopupMenuItem<VoidCallback>(
      label: label,
      value: action,
      icon: icon,
      color: color,
    );
  }

  // ── TODO-609：在线 revision 比对手动更新 ──────────────────────────────

  /// 下载 [dictionary] 来源处的新包并以它为**显式替换目标**重导（BUG-1595：即便
  /// 远端包改了标题也替换这本，而非按 title 误判成新增），保留
  /// order/hidden/collapsed，落上新来源。下载地址与回写来源都取自 [remote]
  /// （BUG-2707：远端 index 声明的新版地址优先，本地旧地址可能钉在旧版本目录）。
  /// 复用现有下载进度 UI（[DictionaryDownloadProgressDialog]）。成功返 true。
  Future<bool> _redownloadAndReimport({
    required Dictionary dictionary,
    required DictionaryRemoteIndexResult remote,
    required DictionaryDownloadJob job,
  }) async {
    // 只喂文案（进度行 / 导入阶段提示 / 完成 toast），无身份用途——身份走
    // `dictionary` 对象本身（downloadUrl / 目录名）。所以这里用显示名：用户改过名
    // 之后，进度条里还蹦出那个又长又带日期的原名会让人以为在更新别的东西。
    final String name = dictionary.effectiveDisplayName;
    final ValueNotifier<String> progressNotifier = job.message;
    final ValueNotifier<double> downloadProgress = job.progress;
    final Directory tempDir = Directory(
      path.join(appModel.dictionaryResourceDirectory.path, 'update_temp'),
    );
    // W-2：更新即知本词典可更新——显式回填 isUpdatable:'true' + 两 URL，使
    // 即便重导包内 index.json 不声明 isUpdatable，更新后仍保持可更新（不丢按钮）。
    final Map<String, String> sourceOverride = remote.updatedSourceMetadata(
      localDownloadUrl: dictionary.downloadUrl,
      localIndexUrl: dictionary.indexUrl,
    );
    try {
      job.markDownloadPhase();
      progressNotifier.value = t.dict_update_updating(name: name);
      downloadProgress.value = 0;
      final File zipFile = await DictionaryDownloader.download(
        url: remote.resolveDownloadUrl(dictionary.downloadUrl),
        tempDir: tempDir,
        progressNotifier: downloadProgress,
        cancelToken: job.cancelToken,
        onBytes: (int received, int total) =>
            progressNotifier.value = dictionaryDownloadStageMessage(
              name: name,
              received: received,
              total: total,
            ),
        // BUG-3887 续：iOS 进程被回收后新进程据此接着下、按同一配方重导。
        handoffPayload: DictionaryImportRecipe.update(
          name: name,
          replaceTargetName: dictionary.name,
          sourceOverride: sourceOverride,
        ).toPayload(),
      );
      enterDictionaryImportStage(
        name: name,
        progressNotifier: progressNotifier,
        downloadProgress: downloadProgress,
        job: job,
      );
      await appModel.importDictionary(
        file: zipFile,
        progressNotifier: progressNotifier,
        onImportSuccess: () {},
        replaceTarget: dictionary,
        sourceOverride: sourceOverride,
      );
      return true;
    } finally {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    }
  }

  /// 单本词典「更新」按钮：拉远端 index.json 比 revision，有新版才下载重导。无新版
  /// 提示「已是最新」。任何失败提示 [t.dict_update_failed]，不崩。
  Future<void> _updateSingleDictionary(Dictionary dictionary) async {
    if (_isDownloading) return;
    if (!dictionary.isUpdatable) return;

    await _runWithDownloadProgressDialog(
      initialMessage: t.dict_update_checking,
      body: (DictionaryDownloadJob job) async {
        // 三种结局（已最新 / 已更新 / 更新失败）共用一条 toast，配色跟着文案一起定，
        // 否则失败也是一条无色提示、与「已是最新」长得一模一样。
        try {
          final DictionaryRemoteIndexResult remote =
              await DictionaryUpdateService.fetchRemoteIndexResult(
                dictionary.indexUrl,
              );
          // 拉不到远端 index 不是「已是最新」——以前两者同一条提示，断网时用户
          // 被告知已最新，其实根本没检查成。
          if (!remote.succeeded) {
            return DictionaryDownloadOutcome(
              message: t.dict_update_check_failed,
              severity: ToastSeverity.error,
            );
          }
          if (!DictionaryUpdateService.needsUpdate(
            dictionary.revision,
            remote.revision,
          )) {
            return DictionaryDownloadOutcome(
              message: t.dict_update_latest,
              severity: ToastSeverity.info,
            );
          }
          await _redownloadAndReimport(
            dictionary: dictionary,
            remote: remote,
            job: job,
          );
          return DictionaryDownloadOutcome(
            message: t.dict_update_done(name: dictionary.effectiveDisplayName),
            severity: ToastSeverity.success,
          );
        } catch (e, stack) {
          // 取消不是失败：不写错误日志，只回一条中性提示。此刻词典库与取消前一致——
          // 取消只可能落在下载传输中，导入一旦开始就到底（BUG-1499）。
          if (DictionaryDownloadController.isCancellation(e)) {
            return DictionaryDownloadOutcome(
              message: t.dict_download_cancelled,
              severity: ToastSeverity.info,
            );
          }
          ErrorLogService.instance.log(
            'DictionaryDialog.updateSingle',
            e,
            stack,
          );
          return DictionaryDownloadOutcome(
            message: t.dict_update_failed(error: '$e'),
            severity: ToastSeverity.error,
          );
        }
      },
    );
  }

  /// TODO-839：本地导入 / 旧词典（isUpdatable=false，无在线来源）的「从文件重选覆盖
  /// 更新」。让用户重选一个词典包，以被点击词典为显式替换目标覆盖它（保留
  /// order/hidden/collapsed），失败不丢原词典（复用 importFromFile 的 import_temp
  /// 暂存→成功才删旧）。
  ///
  /// 异名处理（BUG-1595 已根治旧陷阱）：导入以 `replaceTarget` 显式指定被点击的
  /// 词典，替换语义不再由新包 index.json 的 title 决定——新包异名（含标题携带版本
  /// 号变化）也照样替换原词典，不会再被 decideUpdate 判成 newDictionary 追加成两版
  /// 并存。异名确认框保留：标题变了用户应当知情（仅 yomitan zip 可廉价探出 title；
  /// dsl/mdx 探不到 → 不弹确认直接替换，量极低可接受），确认后执行的是**替换**。
  Future<void> _updateDictionaryFromFile(Dictionary dictionary) async {
    if (_isDownloading) return;

    if (Platform.isAndroid || Platform.isIOS) {
      await FilePicker.platform.clearTemporaryFiles();
    }
    if (!mounted) return;
    final String? pickedPath = await pickSystemFilePath(
      context: context,
      allowedExtensions: const <String>{'zip', 'dsl', 'mdx', 'ifo'},
    );
    if (pickedPath == null) {
      if (Platform.isAndroid || Platform.isIOS) {
        await FilePicker.platform.clearTemporaryFiles();
      }
      return;
    }
    final File file = File(pickedPath);

    // 异名确认：仅 yomitan zip 能廉价探出 title；探到且与目标词典异名时先弹确认。
    final String? incomingTitle = DictionaryImportManager.peekDictionaryTitle(
      file,
    );
    if (incomingTitle != null && incomingTitle != dictionary.name) {
      final bool? confirmed = await _confirmNameMismatch(
        incoming: incomingTitle,
        existing: dictionary.name,
      );
      if (confirmed != true) {
        if (Platform.isAndroid || Platform.isIOS) {
          await FilePicker.platform.clearTemporaryFiles();
        }
        return;
      }
    }

    if (!mounted) return;

    await _runWithDownloadProgressDialog(
      initialMessage: t.dict_update_updating(
        name: dictionary.effectiveDisplayName,
      ),
      body: (DictionaryDownloadJob job) async {
        // 本地文件覆盖更新**全程都是导入阶段**（没有下载），故整条路径不可取消：
        // 进入 body 就切 importing，取消按钮从头到尾是灰的（BUG-1499）。
        job.markImportPhase();
        try {
          await appModel.importDictionary(
            file: file,
            progressNotifier: job.message,
            onImportSuccess: () {},
            // BUG-1595：显式替换被点击的词典。新包异名时不再按 title 判成新增。
            replaceTarget: dictionary,
          );
          // 覆盖导入没抛异常即成功。
          return DictionaryDownloadOutcome(
            message: t.dict_update_done(name: dictionary.effectiveDisplayName),
            severity: ToastSeverity.success,
          );
        } catch (e, stack) {
          ErrorLogService.instance.log(
            'DictionaryDialog.updateFromFile',
            e,
            stack,
          );
          return DictionaryDownloadOutcome(
            message: t.dict_update_failed(error: '$e'),
            severity: ToastSeverity.error,
          );
        }
      },
    );
    if (Platform.isAndroid || Platform.isIOS) {
      await FilePicker.platform.clearTemporaryFiles();
    }
  }

  /// 异名覆盖确认对话框：所选文件包名 [incoming] 与被更新词典 [existing] 不同时弹出，
  /// 用户点「替换」返 true、取消 / 关闭返 null（中止、原词典不动）。
  Future<bool?> _confirmNameMismatch({
    required String incoming,
    required String existing,
  }) {
    return showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => DictionaryConfirmationDialog(
        title: Text(t.dict_update_name_mismatch_title),
        content: Text(
          t.dict_update_name_mismatch_body(
            incoming: incoming,
            existing: existing,
          ),
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: ctx,
            child: Text(t.dialog_cancel),
            onPressed: () => Navigator.pop(ctx),
          ),
          adaptiveDialogAction(
            context: ctx,
            isDefaultAction: true,
            child: Text(t.dialog_replace),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
  }

  /// action bar「检查更新」：遍历所有可更新词典逐个比对，有新版的逐个下载重导，
  /// 汇总 N 更新 / M 最新 / K 失败。复用现有下载进度 UI。
  Future<void> _checkForUpdates() async {
    if (_isDownloading) return;
    final List<Dictionary> updatable = appModel.dictionaries
        .where((Dictionary d) => d.isUpdatable)
        .toList();
    if (updatable.isEmpty) {
      FushiToast.show(
        msg: t.dict_update_all_no_source,
        severity: ToastSeverity.info,
      );
      return;
    }

    await _runWithDownloadProgressDialog(
      initialMessage: t.dict_update_checking,
      body: (DictionaryDownloadJob job) async {
        int updated = 0;
        int current = 0;
        int failed = 0;
        for (final Dictionary d in updatable) {
          // 本间边界：上一本已完整发布，停在这里词典库状态一致（BUG-1499）。
          if (job.isCancelled) break;
          try {
            // W-1：每本检查前归零进度条，避免上一本下载完的满格残留在「检查 revision」
            // 阶段误显 100%。
            job.markDownloadPhase();
            job.progress.value = 0;
            job.message.value = t.dict_update_checking;
            final DictionaryRemoteIndexResult remote =
                await DictionaryUpdateService.fetchRemoteIndexResult(
                  d.indexUrl,
                );
            // 检查失败计入失败，不算「最新」（旧实现把断网也数成最新）。
            if (!remote.succeeded) {
              failed++;
              continue;
            }
            if (!DictionaryUpdateService.needsUpdate(
              d.revision,
              remote.revision,
            )) {
              current++;
              continue;
            }
            await _redownloadAndReimport(
              dictionary: d,
              remote: remote,
              job: job,
            );
            updated++;
          } catch (e, stack) {
            if (DictionaryDownloadController.isCancellation(e)) break;
            ErrorLogService.instance.log(
              'DictionaryDialog.checkUpdates',
              e,
              stack,
            );
            failed++;
          }
        }
        return DictionaryDownloadOutcome(
          message: t.dict_update_summary(
            updated: updated.toString(),
            current: current.toString(),
            failed: failed.toString(),
          ),
          toastLength: Toast.LENGTH_LONG,
          // 有失败即「部分成功」→ warning；全成或全已最新才算 success。
          severity: failed > 0 ? ToastSeverity.warning : ToastSeverity.success,
        );
      },
    );
  }

  // TODO-422：每本词典行尾原来的三点菜单（自定义 CSS + 删除）已移除。2026-10
  // 词典管理重做后删除住在词典详情里（宽屏右侧侧板 / 窄屏底部 sheet，见
  // DictionaryManagerDetail），另有多选批量删除与行内 Delete 键；都走
  // showDictionaryDeleteDialog 同一确认流程。自定义 CSS 仍有设置 → 词典设置里的
  // DictCssEditorDialog 全局入口（可下拉选本词典），故不丢功能。
}

@visibleForTesting
class DictionaryConfirmationDialog extends StatelessWidget {
  const DictionaryConfirmationDialog({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 440,
      maxHeightFactor: 0.78,
      child: FushiModalSheetFrame(
        leadingIcon: Icons.warning_amber_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DefaultTextStyle.merge(
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.type.listTitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
              child: title,
            ),
            SizedBox(height: tokens.spacing.gap),
            DefaultTextStyle.merge(
              style: tokens.type.listSubtitle,
              child: content,
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }
}

@visibleForTesting
class DictionaryDownloadSelectionDialogFrame extends StatelessWidget {
  const DictionaryDownloadSelectionDialogFrame({
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.dict_download_select_title,
        leadingIcon: Icons.cloud_download_outlined,
        scrollable: true,
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
        body: content,
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: actions,
        ),
      ),
    );
  }
}

@visibleForTesting
class DictionaryDownloadProgressDialog extends StatelessWidget {
  const DictionaryDownloadProgressDialog({
    required this.message,
    required this.progressListenable,
    this.detailListenable,
    this.onCancel,
    this.onHide,
    this.cancelDisabledHint,
    super.key,
  });

  final String message;
  final ValueNotifier<double> progressListenable;

  /// 附加说明（BUG-2188）。失败原因这类**必须完整读到**的文案走这里，渲染在正文里、
  /// 可多行、可选中；标题 [message] 是 `maxLines: 1 + ellipsis` 的单行，塞长文案进去
  /// 只会看到被截断的前半段（`DioError [connection ...`）。
  final ValueListenable<String>? detailListenable;

  /// 取消回调。**null = 当前阶段停不下来**（导入中），按钮置灰并显示
  /// [cancelDisabledHint]。给一个按了没反应的按钮比没有按钮更坏（BUG-1499）。
  final VoidCallback? onCancel;

  /// 收起进度框（任务继续在后台跑）。null 时不显示该按钮。
  final VoidCallback? onHide;

  /// 取消不可用时显示的一行说明。
  final String? cancelDisabledHint;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool hasActions = onCancel != null || onHide != null;

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: message,
        leadingIcon: Icons.cloud_download_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          hasActions ? tokens.spacing.gap : tokens.spacing.card,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ValueListenableBuilder<double>(
              valueListenable: progressListenable,
              builder: (_, double progress, __) => FushiLinearProgressIndicator(
                value: progress > 0 ? progress : null,
              ),
            ),
            if (detailListenable != null)
              ValueListenableBuilder<String>(
                valueListenable: detailListenable!,
                builder: (_, String detail, __) => detail.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: EdgeInsets.only(top: tokens.spacing.gap),
                        child: SelectableText(
                          detail,
                          style: tokens.type.listSubtitle,
                          maxLines: 6,
                        ),
                      ),
              ),
            if (onCancel == null && cancelDisabledHint != null) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              Text(cancelDisabledHint!, style: tokens.type.listSubtitle),
            ],
          ],
        ),
        footer: hasActions
            ? Wrap(
                alignment: WrapAlignment.end,
                spacing: tokens.spacing.gap,
                runSpacing: tokens.spacing.gap,
                children: <Widget>[
                  adaptiveDialogAction(
                    context: context,
                    onPressed: onCancel,
                    child: Text(t.dialog_cancel),
                  ),
                  if (onHide != null)
                    adaptiveDialogAction(
                      context: context,
                      isDefaultAction: true,
                      onPressed: onHide,
                      child: Text(t.dict_download_hide),
                    ),
                ],
              )
            : null,
      ),
    );
  }
}

/// 让进度框在任务真正结束时**自己**关闭。
///
/// BUG-1499：旧实现是任务收尾处无条件 `Navigator.pop(context)`——一旦允许用户先把
/// 进度框收起来，那一 pop 就会把词典页本身弹掉。谁开的谁关：本 widget 活在 dialog
/// route 内，监听 [phase]，回到 [DictionaryDownloadPhase.idle] 就 pop 自己；用户
/// 已经手动收起时它早已 dispose、listener 已摘，绝不会误弹别的路由。
@visibleForTesting
class DictionaryDownloadProgressAutoCloser extends StatefulWidget {
  const DictionaryDownloadProgressAutoCloser({
    required this.phase,
    required this.child,
    super.key,
  });

  final ValueListenable<DictionaryDownloadPhase> phase;
  final Widget child;

  @override
  State<DictionaryDownloadProgressAutoCloser> createState() =>
      _DictionaryDownloadProgressAutoCloserState();
}

class _DictionaryDownloadProgressAutoCloserState
    extends State<DictionaryDownloadProgressAutoCloser> {
  @override
  void initState() {
    super.initState();
    widget.phase.addListener(_onPhaseChanged);
    // 任务可能在对话框插进树之前就跑完了（本地覆盖导入的极快路径），此时不会再有
    // 任何一次 phase 变化来触发关闭，必须在首帧后补查一次。
    WidgetsBinding.instance.addPostFrameCallback((_) => _onPhaseChanged());
  }

  @override
  void dispose() {
    widget.phase.removeListener(_onPhaseChanged);
    super.dispose();
  }

  void _onPhaseChanged() {
    if (!mounted) return;
    if (widget.phase.value != DictionaryDownloadPhase.idle) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

@visibleForTesting
class DictionaryLowMemoryDialog extends StatelessWidget {
  const DictionaryLowMemoryDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      child: FushiModalSheetFrame(
        title: t.low_memory_mode,
        leadingIcon: Icons.memory_outlined,
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
        body: Text(
          t.low_memory_mode_suggestion,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
          ],
        ),
      ),
    );
  }
}
