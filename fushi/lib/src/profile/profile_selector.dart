import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/utils/components/fushi_dropdown.dart';

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

    if (uiState.isLoading || uiState.profiles.isEmpty) {
      return const SizedBox.shrink();
    }

    final validId = uiState.profiles.any((p) => p.id == uiState.activeProfileId)
        ? uiState.activeProfileId
        : uiState.profiles.first.id;

    // This selector is embedded as the `trailing` of an AdaptiveSettingsRow,
    // whose Row lays out a non-flex trailing beside an Expanded(label) sibling
    // and therefore measures the trailing with UNBOUNDED main-axis width. A
    // self-sizing, bounded-width dropdown is valid in that slot (a flex child
    // such as `Expanded` would throw "RenderFlex children have non-zero flex but
    // incoming width constraints are unbounded" and blank the page). The bounded
    // 220 width also keeps the trailing from crowding out the row's "配置" label.
    //
    // No gear shortcut here: profile management is reached from Settings →
    // Profiles (a first-class "配置管理" navigation row), so an in-row gear is a
    // redundant entry point that only steals width from the label.
    //
    // Gamepad-enterable MenuAnchor on every polled platform
    // (Windows/Linux/iOS/macOS); a stock DropdownMenu on Android.
    return GamepadMenuDropdown<int>(
      width: 220,
      selected: validId,
      onChanged: (id) {
        if (id != validId) vm.switchProfile(id);
      },
      entries: <GamepadDropdownEntry<int>>[
        for (final p in uiState.profiles) (value: p.id, label: p.name),
      ],
    );
  }
}
