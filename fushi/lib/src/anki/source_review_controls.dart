import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The review toolbar owns navigation and activation while one of its buttons
/// has focus. Media-page shortcuts must not turn Enter into a word lookup or
/// arrow navigation into a page turn before Flutter can activate the button.
class SourceReviewControls extends StatelessWidget {
  const SourceReviewControls({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.tab): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.tab, shift: true):
              PreviousFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowLeft): DirectionalFocusIntent(
            TraversalDirection.left,
          ),
          SingleActivator(LogicalKeyboardKey.arrowRight):
              DirectionalFocusIntent(
            TraversalDirection.right,
          ),
          SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
            TraversalDirection.up,
          ),
          SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
            TraversalDirection.down,
          ),
        },
        child: child,
      );
}
