import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';

/// Full-screen page for managing profiles, media-type bindings,
/// and per-profile settings.
class ProfileManagementPage extends BasePage {
  const ProfileManagementPage({super.key});

  @override
  BasePageState<ProfileManagementPage> createState() =>
      _ProfileManagementPageState();
}

class _ProfileManagementPageState extends BasePageState<ProfileManagementPage> {
  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final uiState = ref.watch(profileViewModelProvider);
    final vm = ref.read(profileViewModelProvider.notifier);

    return AdaptiveSettingsScaffold(
      title: Text(t.profile_management),
      actions: [
        _ProfileActionButton(
          materialIcon: Icons.add,
          cupertinoIcon: CupertinoIcons.add,
          tooltip: t.profile_create,
          onPressed: () => _showCreateDialog(vm),
        ),
      ],
      children: uiState.isLoading
          ? [
              Padding(
                padding:
                    EdgeInsets.symmetric(vertical: tokens.spacing.page * 3),
                child: buildLoading(),
              ),
            ]
          : [
              AdaptiveSettingsSection(
                title: t.profile_label,
                children: _buildProfileRows(uiState, vm),
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
                ],
              ),
            ],
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
    return [
      for (final p in uiState.profiles)
        AdaptiveSettingsRow(
          icon: p.id == uiState.activeProfileId
              ? (cupertino
                  ? CupertinoIcons.check_mark_circled_solid
                  : Icons.check_circle)
              : (cupertino ? CupertinoIcons.circle : Icons.circle_outlined),
          title: p.name,
          onTap: () {
            if (p.id != uiState.activeProfileId) {
              vm.switchProfile(p.id);
            }
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ProfileActionButton(
                materialIcon: Icons.copy_outlined,
                cupertinoIcon: CupertinoIcons.doc_on_doc,
                tooltip: t.profile_copy,
                onPressed: () => _showCopyDialog(vm, p.id, p.name),
              ),
              _ProfileActionButton(
                materialIcon: Icons.edit_outlined,
                cupertinoIcon: CupertinoIcons.pencil,
                tooltip: t.profile_rename,
                onPressed: () => _showRenameDialog(vm, p.id, p.name),
              ),
              if (!isOnly)
                _ProfileActionButton(
                  materialIcon: Icons.delete_outline,
                  cupertinoIcon: CupertinoIcons.delete,
                  tooltip: t.profile_delete,
                  destructive: true,
                  onPressed: () => _showDeleteDialog(vm, p.id, p.name),
                ),
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

    return IconButton(
      icon: Icon(materialIcon, size: 20, color: color),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
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
