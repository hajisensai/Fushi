import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/pages/implementations/profile_management_page.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';

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
      children: [
        Text(
          '${t.profile_label}: ',
          style: theme.textTheme.bodyMedium,
        ),
        Expanded(
          child: DropdownMenu<int>(
            expandedInsets: EdgeInsets.zero,
            initialSelection: validId,
            dropdownMenuEntries: [
              for (final p in uiState.profiles)
                DropdownMenuEntry(value: p.id, label: p.name),
            ],
            onSelected: (id) {
              if (id != null && id != validId) {
                vm.switchProfile(id);
              }
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined, size: 20),
          tooltip: t.profile_management,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () {
            Navigator.push(
              context,
              adaptivePageRoute(builder: (_) => const ProfileManagementPage()),
            );
          },
        ),
      ],
    );
  }
}
