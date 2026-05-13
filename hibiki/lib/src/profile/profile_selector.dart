import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/pages/implementations/profile_management_page.dart';

/// Compact profile selector widget for embedding in settings pages.
///
/// Shows the active profile in a dropdown with a button to open the
/// full management page.
class ProfileSelector extends ConsumerStatefulWidget {
  const ProfileSelector({super.key});

  @override
  ConsumerState<ProfileSelector> createState() => _ProfileSelectorState();
}

class _ProfileSelectorState extends ConsumerState<ProfileSelector> {
  ProfileViewModel? _vm;

  @override
  void initState() {
    super.initState();
    _vm = ref.read(profileViewModelProvider.notifier);
  }

  @override
  void dispose() {
    _vm?.saveCurrentSettingsToActiveProfile();
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
            onChanged: (id) {
              if (id != null && id != uiState.activeProfileId) {
                vm.switchProfile(id);
              }
            },
          ),
        ),
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
}
