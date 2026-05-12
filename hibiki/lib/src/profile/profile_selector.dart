import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/pages/implementations/profile_management_page.dart';

/// Compact profile selector widget for embedding in app bars or settings pages.
///
/// Shows the active profile in a dropdown, with buttons to create a new profile
/// or open the full management page.
class ProfileSelector extends ConsumerStatefulWidget {
  const ProfileSelector({super.key});

  @override
  ConsumerState<ProfileSelector> createState() => _ProfileSelectorState();
}

class _ProfileSelectorState extends ConsumerState<ProfileSelector> {
  @override
  void dispose() {
    // Persist current settings to the active profile on teardown.
    ref.read(profileViewModelProvider.notifier).saveCurrentSettingsToActiveProfile();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uiState = ref.watch(profileViewModelProvider);
    final vm = ref.read(profileViewModelProvider.notifier);
    final theme = Theme.of(context);

    if (uiState.isLoading || uiState.profiles.isEmpty) {
      return const SizedBox.shrink();
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${t.profile_label}: ',
          style: theme.textTheme.bodyMedium,
        ),
        Flexible(
          child: DropdownButton<int>(
            value: uiState.activeProfileId,
            underline: const SizedBox.shrink(),
            isDense: true,
            items: [
              for (final p in uiState.profiles)
                DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (int? id) {
              if (id != null && id != uiState.activeProfileId) {
                vm.switchProfile(id);
              }
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add, size: 20),
          tooltip: t.profile_create,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () => _showCreateDialog(context, vm),
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: const Icon(Icons.settings, size: 20),
          tooltip: t.profile_management,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileManagementPage()),
            );
          },
        ),
      ],
    );
  }

  Future<void> _showCreateDialog(
    BuildContext context,
    ProfileViewModel vm,
  ) async {
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
}
