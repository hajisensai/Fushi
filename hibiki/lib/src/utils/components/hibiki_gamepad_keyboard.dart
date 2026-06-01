import 'package:flutter/material.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

/// An on-screen keyboard driven entirely by a game controller / keyboard: the
/// D-pad moves focus between keys (geometric, via [HibikiFocusController]) and A
/// (ActivateIntent) presses the focused key. It exists because text fields on
/// desktop/console need a way to type without a physical keyboard — the system
/// IME is unavailable there.
///
/// Pure Flutter (no WebView), so its behaviour is unit-testable: pump it inside
/// a [HibikiFocusRoot], move focus with the controller, invoke ActivateIntent,
/// and assert the emitted characters.
///
/// Layers cycle abc → ABC → 123 (symbols) via the `⇧`/`123` key. Control keys
/// (space, backspace, done) sit in the bottom row.
class HibikiGamepadKeyboard extends StatefulWidget {
  const HibikiGamepadKeyboard({
    required this.onChar,
    required this.onBackspace,
    super.key,
    this.onSubmit,
  });

  /// Emitted with the character of the pressed key.
  final ValueChanged<String> onChar;

  /// Pressed the ⌫ key.
  final VoidCallback onBackspace;

  /// Pressed the ✓ (done) key, if provided.
  final VoidCallback? onSubmit;

  @override
  State<HibikiGamepadKeyboard> createState() => _HibikiGamepadKeyboardState();
}

enum _KbLayer { lower, upper, symbols }

class _HibikiGamepadKeyboardState extends State<HibikiGamepadKeyboard> {
  _KbLayer _layer = _KbLayer.lower;

  static const List<String> _lowerRows = <String>[
    'qwertyuiop',
    'asdfghjkl',
    'zxcvbnm',
  ];

  static const List<String> _symbolRows = <String>[
    '1234567890',
    '-/:;()\$&@"',
    ".,?!'",
  ];

  List<String> get _rows {
    switch (_layer) {
      case _KbLayer.lower:
        return _lowerRows;
      case _KbLayer.upper:
        return _lowerRows.map((String r) => r.toUpperCase()).toList();
      case _KbLayer.symbols:
        return _symbolRows;
    }
  }

  String get _layerKeyLabel => _layer == _KbLayer.symbols ? 'abc' : '⇧';

  void _cycleLayer() {
    setState(() {
      switch (_layer) {
        case _KbLayer.lower:
          _layer = _KbLayer.upper;
          break;
        case _KbLayer.upper:
          _layer = _KbLayer.symbols;
          break;
        case _KbLayer.symbols:
          _layer = _KbLayer.lower;
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<String> rows = _rows;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final String row in rows)
          Padding(
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (final String ch in row.split(''))
                  _KbKey(
                    label: ch,
                    onPress: () => widget.onChar(ch),
                  ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _KbKey(label: _layerKeyLabel, onPress: _cycleLayer, flex: 2),
              _KbKey(label: '␣', onPress: () => widget.onChar(' '), flex: 4),
              _KbKey(label: '⌫', onPress: widget.onBackspace, flex: 2),
              if (widget.onSubmit != null)
                _KbKey(label: '✓', onPress: widget.onSubmit!, flex: 2),
            ],
          ),
        ),
      ],
    );
  }
}

/// A single keyboard key: a gamepad/keyboard focus target whose ActivateIntent
/// (A / Enter) fires [onPress].
class _KbKey extends StatefulWidget {
  const _KbKey({
    required this.label,
    required this.onPress,
    this.flex = 1,
  });

  final String label;
  final VoidCallback onPress;
  final int flex;

  @override
  State<_KbKey> createState() => _KbKeyState();
}

class _KbKeyState extends State<_KbKey> {
  late final HibikiFocusId _focusId =
      HibikiFocusId('gamepad-key-${identityHashCode(this)}');

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Widget key = Padding(
      padding: EdgeInsets.all(tokens.spacing.gap / 4),
      child: Material(
        color: tokens.surfaces.overlay,
        shape: RoundedRectangleBorder(borderRadius: tokens.radii.chipRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onPress,
          child: Container(
            constraints: const BoxConstraints(minWidth: 32, minHeight: 40),
            alignment: Alignment.center,
            child: Text(
              widget.label,
              style: tokens.type.controlLabel.copyWith(color: colors.onSurface),
            ),
          ),
        ),
      ),
    );
    // Outside a HibikiFocusRoot (plain widget tests) the key stays a bare
    // tappable; under one it becomes a gamepad focus target. Expanded wraps the
    // WHOLE thing so it remains a direct child of the Row (Expanded must be a
    // direct Flex child, not nested under HibikiFocusTarget).
    final Widget focusable = HibikiFocusRoot.maybeControllerOf(context) == null
        ? key
        : Actions(
            actions: <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
                widget.onPress();
                return null;
              }),
            },
            child: HibikiFocusTarget(id: _focusId, child: key),
          );
    return Expanded(flex: widget.flex, child: focusable);
  }
}

/// Inserts [ch] at the controller's cursor (replacing any selection), leaving
/// the cursor after it. Used by [showGamepadKeyboard].
void gamepadKeyboardInsert(TextEditingController controller, String ch) {
  final TextSelection sel = controller.selection;
  final int start = sel.isValid ? sel.start : controller.text.length;
  final int end = sel.isValid ? sel.end : controller.text.length;
  final String next = controller.text.replaceRange(start, end, ch);
  controller.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: start + ch.length),
  );
}

/// Deletes the selection, or the single character before the cursor.
void gamepadKeyboardBackspace(TextEditingController controller) {
  final TextSelection sel = controller.selection;
  if (sel.isValid && sel.start != sel.end) {
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(sel.start, sel.end, ''),
      selection: TextSelection.collapsed(offset: sel.start),
    );
    return;
  }
  final int pos = sel.isValid ? sel.start : controller.text.length;
  if (pos <= 0) return;
  controller.value = TextEditingValue(
    text: controller.text.replaceRange(pos - 1, pos, ''),
    selection: TextSelection.collapsed(offset: pos - 1),
  );
}

/// Shows [HibikiGamepadKeyboard] in a bottom sheet wired to [controller] — text
/// entry for desktop/console where no system IME exists. Characters insert at
/// the cursor, ⌫ deletes, ✓ dismisses.
Future<void> showGamepadKeyboard(
  BuildContext context,
  TextEditingController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (BuildContext ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: HibikiGamepadKeyboard(
          onChar: (String ch) => gamepadKeyboardInsert(controller, ch),
          onBackspace: () => gamepadKeyboardBackspace(controller),
          onSubmit: () => Navigator.of(ctx).maybePop(),
        ),
      ),
    ),
  );
}
