import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/utils/misc/collection_exporter.dart';
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
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final uiState = ref.watch(profileViewModelProvider);
    final vm = ref.read(profileViewModelProvider.notifier);

    if (uiState.isLoading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: tokens.spacing.page * 3),
        child: Center(
          child: SizedBox(
            width: 36,
            height: 36,
            child: adaptiveIndicator(
              context: context,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
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
            ..._buildProfileRows(uiState, vm),
          ],
        ),
        AdaptiveSettingsSection(
          title: t.profile_media_type_bindings,
          children: [
            _buildMediaTypeRow(
              t.profile_media_epub,
              'epub',
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_srtbook,
              'srtbook',
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_audiobook,
              'audiobook',
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_lyrics,
              'lyrics',
              uiState,
              vm,
            ),
            _buildMediaTypeRow(
              t.profile_media_video,
              'video',
              uiState,
              vm,
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Create row (replaces the original AppBar "+" action)
  // ---------------------------------------------------------------------------

  Widget _buildCreateRow(ProfileViewModel vm) {
    final bool cupertino = isCupertinoPlatform(context);
    return AdaptiveSettingsRow(
      icon: cupertino ? CupertinoIcons.add : Icons.add,
      showIcon: true,
      title: t.profile_create,
      onTap: () => _showCreateDialog(vm),
    );
  }

  Widget _buildImportRow(ProfileViewModel vm) {
    final bool cupertino = isCupertinoPlatform(context);
    return AdaptiveSettingsRow(
      icon: cupertino
          ? CupertinoIcons.square_arrow_down
          : Icons.file_download_outlined,
      showIcon: true,
      title: t.profile_import,
      onTap: () => _importProfile(vm),
    );
  }

  // ---------------------------------------------------------------------------
  // Profile tiles
  // ---------------------------------------------------------------------------

  List<Widget> _buildProfileRows(
    ProfileUiState uiState,
    ProfileViewModel vm,
  ) {
    final isOnly = uiState.profiles.length <= 1;
    final bool cupertino = isCupertinoPlatform(context);
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return [
      for (final profile in uiState.profiles)
        AdaptiveSettingsRow(
          icon: profile.id == uiState.activeProfileId
              ? (cupertino
                  ? CupertinoIcons.check_mark_circled_solid
                  : Icons.check_circle)
              : (cupertino ? CupertinoIcons.circle : Icons.circle_outlined),
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
                materialIcon: Icons.file_upload_outlined,
                cupertinoIcon: CupertinoIcons.square_arrow_up,
                tooltip: t.profile_export,
                onPressed: () => _exportProfile(vm, profile.id, profile.name),
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              _ProfileActionButton(
                materialIcon: Icons.copy_outlined,
                cupertinoIcon: CupertinoIcons.doc_on_doc,
                tooltip: t.profile_copy,
                onPressed: () => _showCopyDialog(vm, profile.id, profile.name),
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              _ProfileActionButton(
                materialIcon: Icons.edit_outlined,
                cupertinoIcon: CupertinoIcons.pencil,
                tooltip: t.profile_rename,
                onPressed: () =>
                    _showRenameDialog(vm, profile.id, profile.name),
              ),
              if (!isOnly) ...[
                SizedBox(width: tokens.spacing.gap / 2),
                _ProfileActionButton(
                  materialIcon: Icons.delete_outline,
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

  Widget _buildMediaTypeRow(
    String label,
    String mediaType,
    ProfileUiState uiState,
    ProfileViewModel vm,
  ) {
    final boundId = uiState.mediaTypeBindings[mediaType];
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
          AdaptiveSettingsPickerOption<int?>(
            value: p.id,
            label: p.name,
          ),
      ],
      onChanged: (id) => vm.setMediaTypeBinding(mediaType, id),
    );
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

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
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => ProfileDeleteDialog(
        profileName: name,
        onConfirm: () => Navigator.pop(ctx, true),
      ),
    );
    if (confirmed == true) {
      await vm.deleteProfile(id);
    }
  }

  // ---------------------------------------------------------------------------
  // Export / Import（单 Profile JSON）
  // ---------------------------------------------------------------------------

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// 文件名安全化：去掉路径分隔符与控制字符，保证可落盘。
  String _sanitizeFileName(String name) {
    final String cleaned =
        name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
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
      fileName: '${_sanitizeFileName(profileName)}.hibikiprofile.json',
      mimeType: 'application/json',
      subject: profileName,
    );
  }

  Future<void> _importProfile(ProfileViewModel vm) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['json'],
    );
    final String? path = result?.files.single.path;
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
    final Color color = destructive
        ? (cupertino
            ? CupertinoColors.destructiveRed.resolveFrom(context)
            : Theme.of(context).colorScheme.error)
        : (cupertino
            ? CupertinoTheme.of(context).primaryColor
            : Theme.of(context).colorScheme.onSurfaceVariant);

    if (cupertino) {
      return CupertinoButton(
        padding: EdgeInsets.zero,
        minSize: 36,
        onPressed: onPressed,
        child: Semantics(
          button: true,
          label: tooltip,
          child: Icon(cupertinoIcon, size: 20, color: color),
        ),
      );
    }

    return HibikiIconButton(
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
    super.key,
  });

  final String profileName;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.9,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.profile_delete,
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
        body: Text(
          t.profile_confirm_delete(name: profileName),
          style: tokens.type.listSubtitle,
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
              onPressed: onConfirm,
              child: Text(t.profile_delete),
            ),
          ],
        ),
      ),
    );
  }
}

@visibleForTesting
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.9,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: widget.title,
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
        body: HibikiTextField(
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
