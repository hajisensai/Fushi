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
    final uiState = ref.watch(profileViewModelProvider);
    final vm = ref.read(profileViewModelProvider.notifier);

    return Scaffold(
      appBar: adaptiveAppBar(
        context: context,
        title: Text(t.profile_management),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: t.profile_create,
            onPressed: () => _showCreateDialog(vm),
          ),
        ],
      ),
      body: uiState.isLoading
          ? buildLoading()
          : ListView(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).padding.bottom + 16,
              ),
              children: [
                ..._buildProfileTiles(uiState, vm),
                const Divider(height: 32),
                _SectionHeader(t.profile_media_type_bindings),
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
    );
  }

  // ---------------------------------------------------------------------------
  // Profile tiles
  // ---------------------------------------------------------------------------

  List<Widget> _buildProfileTiles(
    ProfileUiState uiState,
    ProfileViewModel vm,
  ) {
    final isOnly = uiState.profiles.length <= 1;
    return [
      for (final p in uiState.profiles)
        ListTile(
          leading: Icon(
            p.id == uiState.activeProfileId
                ? Icons.check_circle
                : Icons.circle_outlined,
            color: p.id == uiState.activeProfileId
                ? theme.colorScheme.primary
                : null,
          ),
          title: Text(p.name),
          onTap: () {
            if (p.id != uiState.activeProfileId) {
              vm.switchProfile(p.id);
            }
          },
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.copy_outlined, size: 20),
                tooltip: t.profile_copy,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: () => _showCopyDialog(vm, p.id, p.name),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: t.profile_rename,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: () => _showRenameDialog(vm, p.id, p.name),
              ),
              if (!isOnly)
                IconButton(
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: theme.colorScheme.error,
                  ),
                  tooltip: t.profile_delete,
                  visualDensity: VisualDensity.compact,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: EdgeInsets.zero,
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
    return ListTile(
      title: Text(label),
      trailing: SizedBox(
        width: 160,
        child: DropdownMenu<int?>(
          expandedInsets: EdgeInsets.zero,
          initialSelection: boundId,
          dropdownMenuEntries: [
            DropdownMenuEntry<int?>(
              value: null,
              label: t.profile_media_none,
            ),
            for (final p in uiState.profiles)
              DropdownMenuEntry<int?>(value: p.id, label: p.name),
          ],
          onSelected: (id) => vm.setMediaTypeBinding(mediaType, id),
        ),
      ),
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
    final ThemeData theme = Theme.of(context);

    return adaptiveAlertDialog(
      context: context,
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      buttonPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(
        t.profile_delete,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: double.maxFinite,
          maxHeight: MediaQuery.of(context).size.height * 0.34,
        ),
        child: SingleChildScrollView(
          child: Text(
            t.profile_confirm_delete(name: profileName),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
      actions: [
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
    return adaptiveAlertDialog(
      context: context,
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(
          hintText: t.profile_name_hint,
          isDense: true,
        ),
        onSubmitted: (value) => _submit(context, value),
      ),
      actions: [
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
    );
  }

  void _submit(BuildContext context, String value) {
    Navigator.pop(context, value.trim());
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}
