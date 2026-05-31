import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/profile_management_page.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
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
    // and therefore measures the trailing with UNBOUNDED main-axis width. The
    // old code wrapped the dropdown in an `Expanded` (a flex child), which under
    // unbounded width threw "RenderFlex children have non-zero flex but incoming
    // width constraints are unbounded" (debug), blanking the Anki settings page.
    // The fix is to remove the flex child: the dropdown sizes to its content and
    // is capped by a ConstrainedBox (mirroring AdaptiveSettingsPickerRow's
    // bounded dropdown), so it never demands unbounded width and stays narrow
    // enough not to overflow tight rows. `mainAxisSize.min` keeps the row
    // shrink-wrapping (matching this widget's Cupertino branch). The row title
    // already shows the profile label, so no in-widget label prefix is needed.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Gamepad-enterable MenuAnchor on every polled platform
        // (Windows/Linux/iOS/macOS); a stock DropdownMenu on Android. Bounded
        // width keeps it valid as a non-flex Row trailing.
        GamepadMenuDropdown<int>(
          width: 220,
          selected: validId,
          onChanged: (id) {
            if (id != validId) vm.switchProfile(id);
          },
          entries: <GamepadDropdownEntry<int>>[
            for (final p in uiState.profiles) (value: p.id, label: p.name),
          ],
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: CupertinoButton(
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
          ),
        ),
        CupertinoButton(
          minSize: 30,
          padding: EdgeInsets.zero,
          onPressed: () {
            Navigator.push(
              context,
              adaptivePageRoute(
                context: context,
                builder: (_) => const ProfileManagementPage(),
              ),
            );
          },
          child: Icon(
            CupertinoIcons.gear_alt,
            size: 20,
            color: secondaryLabel,
          ),
        ),
      ],
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
