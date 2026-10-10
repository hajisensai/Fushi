import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi/src/media/video/video_m3e_chrome.dart';

/// Top chrome of an authored disc menu, shown over the disc's own picture.
///
/// The disc menu replaces the regular media_kit controls, so their auto-hide
/// never reaches this bar; it follows its own [visible] source instead (driven
/// by the page with the same 2 s idle timeout as the controls). While hidden it
/// does not hit-test, so clicks fall through to the disc's buttons. Hovering or
/// focusing the bar reports back through [onHoverChanged] / [onFocusChanged] so
/// the page holds it open while it is being used.
///
/// The bar content ([child]) is built from the player's shared top-bar parts
/// (MD3 Expressive floating pills / Apple glass), never a private style.
class BlurayDiscMenuChrome extends StatelessWidget {
  const BlurayDiscMenuChrome({
    required this.visible,
    required this.transitionDuration,
    required this.slideEnabled,
    required this.hiddenOffset,
    required this.margin,
    required this.onHoverChanged,
    required this.onFocusChanged,
    required this.child,
    super.key,
  });

  final ValueListenable<bool> visible;
  final Duration transitionDuration;

  /// MD3 Expressive spring slide (off for the Apple design system).
  final bool slideEnabled;
  final Offset hiddenOffset;
  final EdgeInsets margin;
  final ValueChanged<bool> onHoverChanged;
  final ValueChanged<bool> onFocusChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
    top: 0,
    left: 0,
    right: 0,
    child: SafeArea(
      bottom: false,
      child: Padding(
        padding: margin,
        child: ValueListenableBuilder<bool>(
          valueListenable: visible,
          child: VideoM3eChromeSlide(
            enabled: slideEnabled,
            visible: visible,
            hiddenOffset: hiddenOffset,
            child: MouseRegion(
              onEnter: (PointerEnterEvent _) => onHoverChanged(true),
              onExit: (PointerExitEvent _) => onHoverChanged(false),
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: onFocusChanged,
                child: child,
              ),
            ),
          ),
          builder: (BuildContext _, bool shown, Widget? bar) => IgnorePointer(
            ignoring: !shown,
            child: AnimatedOpacity(
              opacity: shown ? 1 : 0,
              duration: transitionDuration,
              child: bar,
            ),
          ),
        ),
      ),
    ),
  );
}
