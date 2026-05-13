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

class _ProfileManagementPageState
    extends BasePageState<ProfileManagementPage> {
  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(profileViewModelProvider);
    final vm = ref.read(profileViewModelProvider.notifier);

    return Scaffold(
      appBar: AppBar(
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
                  t.profile_media_audiobook,
                  'audiobook',
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
                icon: const Icon(Icons.copy, size: 20),
                tooltip: t.profile_copy,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: () => _showCopyDialog(vm, p.id, p.name),
              ),
              IconButton(
                icon: const Icon(Icons.edit, size: 20),
                tooltip: t.profile_rename,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                padding: EdgeInsets.zero,
                onPressed: () => _showRenameDialog(vm, p.id, p.name),
              ),
              if (!isOnly)
                IconButton(
                  icon: Icon(
                    Icons.delete,
                    size: 20,
                    color: theme.colorScheme.error,
                  ),
                  tooltip: t.profile_delete,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
      trailing: DropdownButton<int?>(
        value: boundId,
        underline: const SizedBox.shrink(),
        items: [
          DropdownMenuItem<int?>(
            value: null,
            child: Text(t.profile_media_none),
          ),
          for (final p in uiState.profiles)
            DropdownMenuItem<int?>(value: p.id, child: Text(p.name)),
        ],
        onChanged: (id) => vm.setMediaTypeBinding(mediaType, id),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Dialogs
  // ---------------------------------------------------------------------------

  Future<void> _showCreateDialog(ProfileViewModel vm) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.profile_create),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.profile_name_hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_close),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(t.dialog_create),
          ),
        ],
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
    final controller = TextEditingController(text: '$sourceName (copy)');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.profile_copy),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.profile_name_hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_close),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(t.dialog_create),
          ),
        ],
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
    final controller = TextEditingController(text: currentName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.profile_rename),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: t.profile_name_hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dialog_close),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(t.dialog_create),
          ),
        ],
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.profile_delete),
        content: Text(t.profile_confirm_delete(name: name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_close),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.profile_delete,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await vm.deleteProfile(id);
    }
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
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
