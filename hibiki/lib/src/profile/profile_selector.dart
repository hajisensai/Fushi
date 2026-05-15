import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/pages/implementations/profile_management_page.dart';

/// Compact profile selector widget for embedding in settings pages.
///
/// Shows the active profile in a dropdown with a button to open the
/// full management page.
class ProfileSelector extends ConsumerWidget {
  const ProfileSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uiState = ref.watch(profileViewModelProvider);
    final vm = ref.read(profileViewModelProvider.notifier);
    final theme = Theme.of(context);

    if (uiState.isLoading || uiState.profiles.isEmpty) {
      return const SizedBox.shrink();
    }

    final validId = uiState.profiles.any((p) => p.id == uiState.activeProfileId)
        ? uiState.activeProfileId
        : uiState.profiles.first.id;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${t.profile_label}: ',
          style: theme.textTheme.bodyMedium,
        ),
        Flexible(
          child: DropdownButton<int>(
            value: validId,
            underline: const SizedBox.shrink(),
            isDense: true,
            items: [
              for (final p in uiState.profiles)
                DropdownMenuItem(value: p.id, child: Text(p.name)),
            ],
            onChanged: (id) {
              if (id != null && id != validId) {
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
