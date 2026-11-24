import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart' show ProfileMediaKind;
import 'package:fushi/src/pages/base_page.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/utils/misc/safe_file_name.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/profile/combo/combo_migration_report_dialog.dart'
    show showComboMigrationReportDialog;
import 'package:fushi/src/profile/combo/combo_repository.dart'
    show ComboMigrationReport;
import 'package:fushi/src/profile/profile_deletion_cascade.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/pages/implementations/combo_editor_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_library_merge_dialog.dart';
import 'package:fushi/src/srs/srs_library_merge.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart'
    show SettingsSectionFooter;
import 'package:fushi/src/utils/misc/collection_exporter.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:path/path.dart' as p;

/// Full-screen page for managing profiles, media-type bindings,
/// and per-profile settings.
///
/// 薄壳：只负责套上脚手架与标题；正文全在 [ProfileManagementBody]，以便同一份
/// 正文既能作为独立路由页（`AppModel.showProfilesMenu`），又能直接平铺进「配置
/// 方案」设置 destination（见 `SettingsDestination.body`），消掉一层子菜单跳转。
class ProfileManagementPage extends BasePage {
  const ProfileManagementPage({super.key});

  @override
  BasePageState<ProfileManagementPage> createState() =>
      _ProfileManagementPageState();
}

class _ProfileManagementPageState extends BasePageState<ProfileManagementPage> {
  @override
  Widget build(BuildContext context) {
    return AdaptiveSettingsScaffold(
      title: Text(t.profile_management),
      children: const [ProfileManagementBody()],
    );
  }
}

/// Profile 管理正文（无脚手架）。返回一个 [Column]，自身不带 `Scaffold` / 独立
/// 滚动——外层（脚手架或设置渲染器）已提供滚动与内边距。
///
/// 原页面的 AppBar「+新建」操作在这里下沉成正文顶部的「新建配置」行，使内嵌进
/// 设置页时也能新建（设置详情页没有 AppBar 操作槽）。
class ProfileManagementBody extends ConsumerStatefulWidget {
  const ProfileManagementBody({super.key});

  @override
  ConsumerState<ProfileManagementBody> createState() =>
      _ProfileManagementBodyState();
}

class _ProfileManagementBodyState extends ConsumerState<ProfileManagementBody> {
  @override
  void initState() {
    super.initState();
    // 一次性存量扫描：以前删 Profile 只删 profiles 行，留在 srs.db 里的无主复习数据在这里先备份再清掉
    // （扫完记标记，之后进来是空操作）。失败进错误日志，下次进来再扫。
    final ProfileViewModel vm = ref.read(profileViewModelProvider.notifier);
    vm.sweepOrphanProfileData().catchError((Object e, StackTrace stack) {
      ErrorLogService.instance.log('ProfileManagement.sweepOrphans', e, stack);
      return 0;
    });
    // 「合并进共享复习库」内核已并完、组合还没恢复继承的（进程在两步之间被杀）：补做。
    vm.finishPendingSrsLibraryMerges().catchError((Object e, StackTrace stack) {
      ErrorLogService.instance.log(
        'ProfileManagement.finishSrsLibraryMerges',
        e,
        stack,
      );
      return 0;
    });
    // 组合迁移报告（拍板台 design-combo-node-split）：迁移改写过存量配置时可在这里重看。
    vm.comboMigrationReport().then((ComboMigrationReport? report) {
      if (mounted && report != null) setState(() => _migrationReport = report);
    });
  }

  ComboMigrationReport? _migrationReport;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final uiState = ref.watch(profileViewModelProvider);
    final vm = ref.read(profileViewModelProvider.notifier);

    if (uiState.isLoading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.page * 3),
        // 统一加载占位（MD3 Expressive 指示器 / Apple 系统菊花）。
        child: const FushiLoadingView(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 标题留空：内嵌进「配置方案」设置页时，上方 schema 的「配置」picker 节
        // 已带「配置」标题，这里再挂一次会重复；作为独立路由页（showProfilesMenu）
        // 时脚手架标题已是「配置管理」，本节作为其延续也无需再重复表头。
        AdaptiveSettingsSection(
          children: [
            _buildCreateRow(vm),
            _buildImportRow(vm),
            if (_migrationReport case final ComboMigrationReport report)
              _buildMigrationReportRow(report),
            ..._buildProfileRows(uiState, vm),
          ],
        ),
        AdaptiveSettingsSection(
          title: t.profile_media_type_bindings,
          children: [
            _buildMediaTypeRow(
              t.profile_media_epub,
              ProfileMediaKind.epub,
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_srtbook,
              ProfileMediaKind.srtbook,
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_audiobook,
              ProfileMediaKind.audiobook,
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_lyrics,
              ProfileMediaKind.lyrics,
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_video,
              ProfileMediaKind.video,
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_manga,
              ProfileMediaKind.manga,
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_game,
              ProfileMediaKind.game,
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_browser,
              ProfileMediaKind.browser,
              uiState,
              vm,
            ),
          ],
        ),
        // 语言绑定的优先级低于上面的媒体类型绑定与书架上的单条目绑定（组合模型逐叶子解析：
        // 作品 > 媒体类型 > 语言 > 默认，拍板台 design-combo-node-split）。
        AdaptiveSettingsSection(
          title: t.profile_language_bindings,
          children: [
            for (final String tag in _languageBindingTags(uiState))
              _buildLanguageRow(tag, uiState, vm),
          ],
        ),
        // 说明不再伪装成分组里的第一行（标题被截断、还带行高 / 分隔线语义），
        // 改成与 schema section footer 同款的分组脚注（样式按设计系统由
        // SettingsSectionFooter 自己取：Apple footnote 灰字 / MD3 bodySmall
        // onVariant）。
        SettingsSectionFooter(t.profile_language_bindings_hint),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Create row (replaces the original AppBar "+" action)
  // ---------------------------------------------------------------------------

  Widget _buildCreateRow(ProfileViewModel vm) {
    final bool cupertino = isCupertinoPlatform(context);
    return AdaptiveSettingsRow(
      icon: cupertino ? CupertinoIcons.add : FushiIcons.add,
      showIcon: true,
      title: t.profile_create,
      onTap: () => _showCreateDialog(vm),
    );
  }

  Widget _buildImportRow(ProfileViewModel vm) {
    final bool cupertino = isCupertinoPlatform(context);
    return AdaptiveSettingsRow(
      icon: cupertino ? CupertinoIcons.square_arrow_down : FushiIcons.download,
      showIcon: true,
      title: t.profile_import,
      onTap: () => _importProfile(vm),
    );
  }

  Widget _buildMigrationReportRow(ComboMigrationReport report) {
    final bool cupertino = isCupertinoPlatform(context);
    return AdaptiveSettingsRow(
      key: const ValueKey<String>('profile_combo_migration_report_row'),
      icon: cupertino ? CupertinoIcons.info : FushiIcons.info,
      showIcon: true,
      title: t.profile_combo_migration_view,
      onTap: () => showComboMigrationReportDialog(context, report),
    );
  }

  // ---------------------------------------------------------------------------
  // Profile tiles
  // ---------------------------------------------------------------------------

  List<Widget> _buildProfileRows(ProfileUiState uiState, ProfileViewModel vm) {
    final isOnly = uiState.profiles.length <= 1;
    final bool cupertino = isCupertinoPlatform(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return [
      for (final profile in uiState.profiles)
        AdaptiveSettingsRow(
          icon: profile.id == uiState.activeProfileId
              ? (cupertino
                    ? CupertinoIcons.check_mark_circled_solid
                    : FushiIcons.filled(FushiIcons.success))
              : (cupertino ? CupertinoIcons.circle : FushiIcons.profiles),
          // 行首的实心 / 空心圆就是「当前激活」的唯一信号——不 showIcon 的话
          // 共享行根本不画它，列表里看不出哪个方案在用。
          showIcon: true,
          title: profile.name,
          onTap: () {
            if (profile.id != uiState.activeProfileId) {
              vm.switchProfile(profile.id);
            }
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ProfileActionButton(
                materialIcon: FushiIcons.upload,
                cupertinoIcon: CupertinoIcons.square_arrow_up,
                tooltip: t.profile_export,
                onPressed: () => _exportProfile(vm, profile.id, profile.name),
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              _ProfileActionButton(
                materialIcon: FushiIcons.copy,
                cupertinoIcon: CupertinoIcons.doc_on_doc,
                tooltip: t.profile_copy,
                onPressed: () => _showCopyDialog(vm, profile.id, profile.name),
              ),
              // 组合编辑（阶段 6）：只有默认组合时不出现「组合」概念（设置页照常编辑默认值）。
              // 复习库的「拆成独立库 / 合并进共享库」也在编辑页的复习库项上。
              if (!isOnly) ...[
                SizedBox(width: tokens.spacing.gap / 2),
                _ProfileActionButton(
                  key: ValueKey<String>('profile_edit_combo_${profile.id}'),
                  materialIcon: FushiIcons.widgets,
                  cupertinoIcon: CupertinoIcons.square_stack_3d_up,
                  tooltip: t.profile_combo_edit,
                  onPressed: () => _openComboEditor(profile.id),
                ),
              ],
              SizedBox(width: tokens.spacing.gap / 2),
              _ProfileActionButton(
                materialIcon: FushiIcons.rename,
                cupertinoIcon: CupertinoIcons.pencil,
                tooltip: t.profile_rename,
                onPressed: () =>
                    _showRenameDialog(vm, profile.id, profile.name),
              ),
              if (!isOnly) ...[
                SizedBox(width: tokens.spacing.gap / 2),
                _ProfileActionButton(
                  materialIcon: FushiIcons.delete,
                  cupertinoIcon: CupertinoIcons.delete,
                  tooltip: t.profile_delete,
                  destructive: true,
                  onPressed: () =>
                      _showDeleteDialog(vm, profile.id, profile.name),
                ),
              ],
            ],
          ),
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // Media-type binding rows
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Language binding rows
  // ---------------------------------------------------------------------------

  /// 要铺出来的语言标签：内容语言选择器的标准候选（用户能在条目上设的那几个）
  /// 打头，后面接「已绑定但不在标准候选里」的标签。
  ///
  /// 后半段不是多余的：`EpubBooks.language` 是从 EPUB 的 `dc:language` 自动回填
  /// 的，值域是整个 BCP-47（一本法语书就会写进 `fr`）。少了这一段，用户给这类
  /// 语言建的绑定会在 UI 上彻底消失——看不见、也改不掉，只能观察到「Profile 莫名
  /// 其妙自己切了」。
  List<String> _languageBindingTags(ProfileUiState uiState) {
    final List<String> standard = <String>[
      for (final ({String? tag, String label}) option
          in kContentLanguageOptions)
        if (option.tag != null) option.tag!,
    ];
    final List<String> extras =
        uiState.languageBindings.keys
            .where((String tag) => !standard.contains(tag))
            .toList()
          ..sort();
    return <String>[...standard, ...extras];
  }

  Widget _buildLanguageRow(
    String languageTag,
    ProfileUiState uiState,
    ProfileViewModel vm,
  ) {
    final int? boundId = uiState.languageBindings[languageTag];
    return AdaptiveSettingsPickerRow<int?>(
      title: contentLanguageLabelOf(languageTag),
      selected: boundId,
      materialWidth: 176,
      options: [
        AdaptiveSettingsPickerOption<int?>(
          value: null,
          label: t.profile_media_none,
        ),
        for (final p in uiState.profiles)
          AdaptiveSettingsPickerOption<int?>(value: p.id, label: p.name),
      ],
      onChanged: (int? id) => vm.setLanguageBinding(languageTag, id),
    );
  }

  Widget _buildMediaTypeRow(
    String label,
    ProfileMediaKind mediaType,
    ProfileUiState uiState,
    ProfileViewModel vm,
  ) {
    final boundId = uiState.mediaTypeBindings[mediaType.dbValue];
    return AdaptiveSettingsPickerRow<int?>(
      title: label,
      selected: boundId,
      materialWidth: 176,
      options: [
        AdaptiveSettingsPickerOption<int?>(
          value: null,
          label: t.profile_media_none,
        ),
        for (final p in uiState.profiles)
          AdaptiveSettingsPickerOption<int?>(value: p.id, label: p.name),
      ],
      onChanged: (id) => vm.setMediaTypeBinding(mediaType, id),
    );
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  /// 组合编辑页（阶段 6）。
  Future<void> _openComboEditor(int profileId) {
    final ProfileViewModel vm = ref.read(profileViewModelProvider.notifier);
    return Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (_) => ComboEditorPage(
          profileId: profileId,
          editing: vm,
          onMergeSrsLibrary: (BuildContext ctx, int id) =>
              _runSrsLibraryMergeFlow(ctx, vm, id),
        ),
      ),
    );
  }

  /// 「合并进共享复习库」（组合阶段 5）：先读预览（冲突表），再弹确认框；合并在框里跑。入口在组合
  /// 编辑页的复习库项上。
  static Future<void> _runSrsLibraryMergeFlow(
    BuildContext context,
    ProfileViewModel vm,
    int profileId,
  ) async {
    final SrsLibraryMergePlan? plan;
    try {
      plan = await vm.srsLibraryMergePlan(profileId);
    } catch (e, stack) {
      ErrorLogService.instance.log('ProfileManagement.mergePlan', e, stack);
      FushiToast.show(
        msg: _srsMergeErrorText(e),
        toastLength: Toast.LENGTH_LONG,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (plan == null || !context.mounted) return;
    final SrsMergeResult? result = await showSrsLibraryMergeDialog(
      context,
      plan: plan,
      run: (Map<String, SrsMergeChoice> r) =>
          vm.mergeSrsLibraryIntoShared(plan!, r),
      errorText: (Object e) {
        ErrorLogService.instance.log('ProfileManagement.mergeSrsLibrary', e);
        return _srsMergeErrorText(e);
      },
    );
    if (result != null) FushiToast.show(msg: t.srs_library_merge_done);
  }

  static String _srsMergeErrorText(Object e) => switch (e) {
    SrsLibraryMergeStaleException() => t.srs_library_merge_stale,
    SrsLibraryMergeUnavailableException() => t.srs_library_merge_unavailable,
    _ => t.srs_library_merge_failed,
  };

  Future<void> _showCreateDialog(ProfileViewModel vm) async {
    final name = await showAppDialog<String>(
      context: context,
      builder: (ctx) => ProfileNameDialog(
        title: t.profile_create,
        initialName: '',
        submitLabel: t.dialog_create,
      ),
    );
    if (name != null && name.isNotEmpty) {
      await vm.createProfile(name);
    }
  }

  Future<void> _showCopyDialog(
    ProfileViewModel vm,
    int sourceId,
    String sourceName,
  ) async {
    final name = await showAppDialog<String>(
      context: context,
      builder: (ctx) => ProfileNameDialog(
        title: t.profile_copy,
        initialName: '$sourceName ${t.profile_copy_suffix}',
        submitLabel: t.dialog_create,
      ),
    );
    if (name != null && name.isNotEmpty) {
      await vm.copyProfile(sourceId, name);
    }
  }

  Future<void> _showRenameDialog(
    ProfileViewModel vm,
    int id,
    String currentName,
  ) async {
    final name = await showAppDialog<String>(
      context: context,
      builder: (ctx) => ProfileNameDialog(
        title: t.profile_rename,
        initialName: currentName,
        submitLabel: t.dialog_save,
      ),
    );
    if (name != null && name.isNotEmpty) {
      await vm.renameProfile(id, name);
    }
  }

  Future<void> _showDeleteDialog(
    ProfileViewModel vm,
    int id,
    String name,
  ) async {
    // 确认框写明会连带删掉的复习数据（srs.db 不在主库外键级联里，删 Profile 时由 Rust 一并清掉）。统计失败也
    // 不能让异常逃出按钮回调（那样确认框不弹、什么提示都没有，BUG-5275）：复习库打不开时确认框照弹、写明原因、
    // 删除按钮不可点；其余失败给提示。
    ProfileDeletionImpact impact = const ProfileDeletionImpact.none();
    String? blockedReason;
    try {
      impact = await vm.deletionImpact(id);
    } on ProfileHostsSharedSrsLibraryException {
      // 承载共享复习库（组合阶段 4）：不是错误，确认框写明为什么不能删。
      blockedReason = t.profile_delete_hosts_shared_srs_library;
    } on ProfileDeletionSrsUnavailableException catch (e, stack) {
      ErrorLogService.instance.log('ProfileManagement.deleteImpact', e, stack);
      blockedReason = t.profile_delete_srs_unavailable;
    } catch (e, stack) {
      ErrorLogService.instance.log('ProfileManagement.deleteImpact', e, stack);
      FushiToast.show(
        msg: t.profile_delete_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (!mounted) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => ProfileDeleteDialog(
        profileName: name,
        impact: impact,
        blockedReason: blockedReason,
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed != true) return;
    final ProfileDeletionOutcome? outcome;
    try {
      outcome = await vm.deleteProfile(id);
    } on ProfileHostsSharedSrsLibraryException {
      FushiToast.show(
        msg: t.profile_delete_hosts_shared_srs_library,
        toastLength: Toast.LENGTH_LONG,
        severity: ToastSeverity.error,
      );
      return;
    } on ProfileDeletionSrsUnavailableException catch (e, stack) {
      // 确认之后复习库才变得打不开（例如别的窗口开始升级）：删除已中止，Profile 原样保留。
      ErrorLogService.instance.log('ProfileManagement.delete', e, stack);
      FushiToast.show(
        msg: t.profile_delete_srs_unavailable,
        toastLength: Toast.LENGTH_LONG,
        severity: ToastSeverity.error,
      );
      return;
    } on ProfileDeletionBackupException catch (e, stack) {
      ErrorLogService.instance.log('ProfileManagement.deleteBackup', e, stack);
      FushiToast.show(
        msg: t.profile_delete_srs_backup_failed,
        severity: ToastSeverity.error,
      );
      return;
    } catch (e, stack) {
      ErrorLogService.instance.log('ProfileManagement.delete', e, stack);
      FushiToast.show(
        msg: t.profile_delete_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    final String? backup = outcome?.backupPath;
    if (backup != null) {
      FushiToast.show(
        msg: t.profile_delete_srs_backed_up(path: backup),
        toastLength: Toast.LENGTH_LONG,
        severity: ToastSeverity.success,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Export / Import（单 Profile JSON）
  // ---------------------------------------------------------------------------

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  /// 文件名安全化：去掉路径分隔符与控制字符，保证可落盘。
  String _sanitizeFileName(String name) {
    final String cleaned = safeWindowsFileName(name).trim();
    return cleaned.isEmpty ? 'profile' : cleaned;
  }

  Future<void> _exportProfile(
    ProfileViewModel vm,
    int profileId,
    String profileName,
  ) async {
    final AppModel appModel = ref.read(appProvider);
    final String fontsRoot = p.join(appModel.appDirectory.path, 'custom_fonts');
    String content;
    try {
      content = await vm.exportProfile(
        profileId,
        fontsRootDirectory: fontsRoot,
      );
    } catch (_) {
      _notify(t.profile_export_failed);
      return;
    }
    if (!mounted) return;
    await saveOrShareExport(
      context: context,
      content: content,
      // 导入侧按 allowedExtensions: ['json'] 过滤，不认中间这段，所以改名不会
      // 让用户已导出的 .hibikiprofile.json 变得无法导入。
      fileName: '${_sanitizeFileName(profileName)}.fushiprofile.json',
      mimeType: 'application/json',
      subject: profileName,
    );
  }

  Future<void> _importProfile(ProfileViewModel vm) async {
    final String? path = await pickSystemFilePath(
      context: context,
      allowedExtensions: <String>{'json'},
    );
    if (path == null) return;

    String json;
    try {
      json = await File(path).readAsString();
    } catch (_) {
      if (mounted) _notify(t.profile_import_failed);
      return;
    }

    try {
      await vm.importProfile(json);
      _notify(t.profile_import_success);
    } on ProfileImportException {
      // 坏文件 / 魔数不符 / 版本不兼容：DB 未被触碰（事务零破坏）。
      _notify(t.profile_import_invalid);
    } catch (_) {
      _notify(t.profile_import_failed);
    }
  }
}

class _ProfileActionButton extends StatelessWidget {
  const _ProfileActionButton({
    super.key,
    required this.materialIcon,
    required this.cupertinoIcon,
    required this.tooltip,
    required this.onPressed,
    this.destructive = false,
  });

  final IconData materialIcon;
  final IconData cupertinoIcon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final bool cupertino = isCupertinoPlatform(context);
    // Apple：行内操作字形是强调色（iOS 列表行里的可点图标口径），删除用系统
    // destructive 红；MD3 维持中性 onSurfaceVariant / error。
    final bool glass = !cupertino && isGlassDesign(context);
    final Color color = destructive
        ? (cupertino
              ? CupertinoColors.destructiveRed.resolveFrom(context)
              : glass
              ? appleColorsOf(context).destructive
              : Theme.of(context).colorScheme.error)
        : (cupertino
              ? CupertinoTheme.of(context).primaryColor
              : glass
              ? appleColorsOf(context).accent
              : Theme.of(context).colorScheme.onSurfaceVariant);

    if (cupertino) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minSize: 36,
        onPressed: onPressed,
        child: Semantics(
          button: true,
          label: tooltip,
          child: FushiIcon(cupertinoIcon, size: 20, color: color),
        ),
      );
    }

    return FushiIconButton(
      icon: materialIcon,
      size: 20,
      tooltip: tooltip,
      enabledColor: color,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      onTap: onPressed,
    );
  }
}

@visibleForTesting
class ProfileDeleteDialog extends StatelessWidget {
  const ProfileDeleteDialog({
    required this.profileName,
    required this.onConfirm,
    this.impact = const ProfileDeletionImpact.none(),
    this.blockedReason,
    super.key,
  });

  final String profileName;
  final VoidCallback onConfirm;

  /// 会连带删掉的复习数据；有数据时正文多一段写明卡数、复习记录数与自动备份。
  final ProfileDeletionImpact impact;

  /// 此刻删不了的原因（复习库打不开、没法先备份，BUG-5275）：非 null 时正文写明原因，删除按钮不可点。
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.9,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.profile_delete,
        leadingIcon: FushiIcons.delete,
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
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.profile_confirm_delete(name: profileName),
              style: tokens.type.listSubtitle,
            ),
            if (blockedReason case final String reason) ...[
              SizedBox(height: tokens.spacing.gap),
              Text(
                reason,
                key: const ValueKey<String>('profile_delete_blocked_reason'),
                style: tokens.type.listSubtitle,
              ),
            ] else if (impact.hasSrsData) ...[
              SizedBox(height: tokens.spacing.gap),
              Text(
                t.profile_delete_srs_impact(
                  cards: impact.srsCards,
                  reviews: impact.srsReviews,
                ),
                key: const ValueKey<String>('profile_delete_srs_impact'),
                style: tokens.type.listSubtitle,
              ),
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.dialog_close),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: blockedReason == null ? onConfirm : null,
              child: Text(t.profile_delete),
            ),
          ],
        ),
      ),
    );
  }
}

/// 配置名输入框（新建 / 复制 / 改名，及作品「存成组合」）。
class ProfileNameDialog extends StatefulWidget {
  const ProfileNameDialog({
    required this.title,
    required this.initialName,
    required this.submitLabel,
    super.key,
  });

  final String title;
  final String initialName;
  final String submitLabel;

  @override
  State<ProfileNameDialog> createState() => _ProfileNameDialogState();
}

class _ProfileNameDialogState extends State<ProfileNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.9,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: FushiModalSheetFrame(
        title: widget.title,
        leadingIcon: FushiIcons.profiles,
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
        body: FushiTextField(
          controller: _controller,
          autofocus: true,
          hintText: t.profile_name_hint,
          onSubmitted: (value) => _submit(context, value),
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_close),
            ),
            adaptiveDialogAction(
              context: context,
              onPressed: () => _submit(context, _controller.text),
              child: Text(widget.submitLabel),
            ),
          ],
        ),
      ),
    );
  }

  void _submit(BuildContext context, String value) {
    Navigator.pop(context, value.trim());
  }
}
