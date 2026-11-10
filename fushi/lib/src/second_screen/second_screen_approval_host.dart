import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/second_screen/companion/companion_bridge.dart';
import 'package:fushi/src/second_screen/companion/companion_main_services.dart';
import 'package:fushi/src/second_screen/second_screen_controller.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// App-root host that owns the second-screen controller's and the companion
/// bridge's lifetime, and asks the one-time "Use this screen for Fushi?"
/// question on the main screen when a new screen shows up (auto policy).
///
/// Pass-through widget: it adds no layout, only listens to
/// [secondScreenControllerProvider], keeps [companionBridgeProvider] alive
/// (its "open on the main screen" links go to [openLink]) and shows the
/// dialog on the app navigator.
class SecondScreenApprovalHost extends ConsumerStatefulWidget {
  const SecondScreenApprovalHost({
    required this.child,
    required this.openLink,
    super.key,
  });

  final Widget child;

  /// main.dart's deep-link handler (`fushi://widget/...` links).
  final CompanionLinkOpener openLink;

  @override
  ConsumerState<SecondScreenApprovalHost> createState() =>
      _SecondScreenApprovalHostState();
}

class _SecondScreenApprovalHostState
    extends ConsumerState<SecondScreenApprovalHost> {
  bool _asking = false;
  late final CompanionBridge _bridge;

  @override
  void initState() {
    super.initState();
    _bridge = ref.read(companionBridgeProvider)..bindOpenLink(widget.openLink);
    // The controller may already need an answer by the time this mounts.
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) _maybeAsk(ref.read(secondScreenControllerProvider));
    });
  }

  @override
  void didUpdateWidget(SecondScreenApprovalHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.openLink != widget.openLink) {
      _bridge.bindOpenLink(widget.openLink);
    }
  }

  @override
  void dispose() {
    _bridge.bindOpenLink(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SecondScreenController>(secondScreenControllerProvider, (
      SecondScreenController? previous,
      SecondScreenController next,
    ) {
      _maybeAsk(next);
    });
    return widget.child;
  }

  void _maybeAsk(SecondScreenController controller) {
    if (_asking || !controller.needsApproval) return;
    final BuildContext? navContext = ref
        .read(appProvider)
        .navigatorKey
        .currentContext;
    // The navigator is not mounted yet: the next controller change asks
    // again.
    if (navContext == null || !navContext.mounted) return;
    _asking = true;
    showFushiConfirmDialog(
      context: navContext,
      title: t.second_screen_approval_title,
      message: t.second_screen_approval_message,
      icon: FushiIcons.devices,
      confirmLabel: t.second_screen_approval_use,
      cancelLabel: t.second_screen_approval_decline,
      barrierDismissible: false,
    ).then((bool use) async {
      try {
        await controller.answerApproval(useScreen: use);
      } finally {
        _asking = false;
      }
    });
  }
}
