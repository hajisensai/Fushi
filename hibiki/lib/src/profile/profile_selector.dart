import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/hibiki_dropdown.dart';
import 'package:hibiki_core/hibiki_core.dart';

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

    if (isCupertinoPlatform(context)) {
      return _CupertinoProfileSelector(
        profiles: uiState.profiles,
        validId: validId,
        onSelected: vm.switchProfile,
      );
    }

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

class _CupertinoProfileSelector extends StatelessWidget {
  const _CupertinoProfileSelector({
    required this.profiles,
    required this.validId,
    required this.onSelected,
  });

  final List<ProfileRow> profiles;
  final int validId;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ProfileRow active = profiles.firstWhere(
      (ProfileRow profile) => profile.id == validId,
      orElse: () => profiles.first,
    );
    final Color secondaryLabel = CupertinoColors.secondaryLabel.resolveFrom(
      context,
    );
    // No gear shortcut: profile management lives in Settings → Profiles, so an
    // in-row gear here would only be a redundant entry point. The picker shrinks
    // to its content (ellipsised profile name) and stays a valid self-sizing
    // trailing for AdaptiveSettingsRow's unbounded-width measurement.
    return CupertinoButton(
      minSize: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      onPressed: () => _showProfilePicker(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              active.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            CupertinoIcons.chevron_down,
            size: 14,
            color: secondaryLabel,
          ),
        ],
      ),
    );
  }

  Future<void> _showProfilePicker(BuildContext context) async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (BuildContext modalContext) {
        return CupertinoActionSheet(
          title: Text(t.profile_label),
          actions: <Widget>[
            for (final ProfileRow profile in profiles)
              CupertinoActionSheetAction(
                isDefaultAction: profile.id == validId,
                onPressed: () {
                  Navigator.pop(modalContext);
                  if (profile.id != validId) onSelected(profile.id);
                },
                child: Text(profile.name),
              ),
          ],
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(modalContext),
            child: Text(t.dialog_cancel),
          ),
        );
      },
    );
  }
}
