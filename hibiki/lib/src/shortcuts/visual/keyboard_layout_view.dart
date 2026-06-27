import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/shortcuts/visual/key_cap_widget.dart';
import 'package:hibiki/src/shortcuts/visual/reverse_binding_index.dart';

class _KeySpec {
  const _KeySpec(this.key, this.label, {this.flex = 1});
  final LogicalKeyboardKey key;
  final String label;
  final int flex;
}

class KeyboardLayoutView extends StatelessWidget {
  const KeyboardLayoutView({
    super.key,
    required this.registry,
    required this.scope,
    this.onKeyTap,
  });

  final HibikiShortcutRegistry registry;
  final ShortcutScope scope;

  final void Function(
      LogicalKeyboardKey key, List<ShortcutAction> boundActions)? onKeyTap;

  static const List<List<_KeySpec>> _rows = <List<_KeySpec>>[
    <_KeySpec>[
      _KeySpec(LogicalKeyboardKey.escape, 'Esc'),
      _KeySpec(LogicalKeyboardKey.f1, 'F1'),
      _KeySpec(LogicalKeyboardKey.f2, 'F2'),
      _KeySpec(LogicalKeyboardKey.f3, 'F3'),
      _KeySpec(LogicalKeyboardKey.f4, 'F4'),
      _KeySpec(LogicalKeyboardKey.f5, 'F5'),
      _KeySpec(LogicalKeyboardKey.f6, 'F6'),
      _KeySpec(LogicalKeyboardKey.f7, 'F7'),
      _KeySpec(LogicalKeyboardKey.f8, 'F8'),
      _KeySpec(LogicalKeyboardKey.f9, 'F9'),
      _KeySpec(LogicalKeyboardKey.f10, 'F10'),
      _KeySpec(LogicalKeyboardKey.f11, 'F11'),
      _KeySpec(LogicalKeyboardKey.f12, 'F12'),
    ],
    <_KeySpec>[
      _KeySpec(LogicalKeyboardKey.digit1, '1'),
      _KeySpec(LogicalKeyboardKey.digit2, '2'),
      _KeySpec(LogicalKeyboardKey.digit3, '3'),
      _KeySpec(LogicalKeyboardKey.digit4, '4'),
      _KeySpec(LogicalKeyboardKey.digit5, '5'),
      _KeySpec(LogicalKeyboardKey.digit6, '6'),
      _KeySpec(LogicalKeyboardKey.digit7, '7'),
      _KeySpec(LogicalKeyboardKey.digit8, '8'),
      _KeySpec(LogicalKeyboardKey.digit9, '9'),
      _KeySpec(LogicalKeyboardKey.digit0, '0'),
      _KeySpec(LogicalKeyboardKey.backspace, 'Bksp', flex: 2),
    ],
    <_KeySpec>[
      _KeySpec(LogicalKeyboardKey.tab, 'Tab', flex: 2),
      _KeySpec(LogicalKeyboardKey.keyQ, 'Q'),
      _KeySpec(LogicalKeyboardKey.keyW, 'W'),
      _KeySpec(LogicalKeyboardKey.keyE, 'E'),
      _KeySpec(LogicalKeyboardKey.keyR, 'R'),
      _KeySpec(LogicalKeyboardKey.keyT, 'T'),
      _KeySpec(LogicalKeyboardKey.keyY, 'Y'),
      _KeySpec(LogicalKeyboardKey.keyU, 'U'),
      _KeySpec(LogicalKeyboardKey.keyI, 'I'),
      _KeySpec(LogicalKeyboardKey.keyO, 'O'),
      _KeySpec(LogicalKeyboardKey.keyP, 'P'),
    ],
    <_KeySpec>[
      _KeySpec(LogicalKeyboardKey.keyA, 'A'),
      _KeySpec(LogicalKeyboardKey.keyS, 'S'),
      _KeySpec(LogicalKeyboardKey.keyD, 'D'),
      _KeySpec(LogicalKeyboardKey.keyF, 'F'),
      _KeySpec(LogicalKeyboardKey.keyG, 'G'),
      _KeySpec(LogicalKeyboardKey.keyH, 'H'),
      _KeySpec(LogicalKeyboardKey.keyJ, 'J'),
      _KeySpec(LogicalKeyboardKey.keyK, 'K'),
      _KeySpec(LogicalKeyboardKey.keyL, 'L'),
      _KeySpec(LogicalKeyboardKey.enter, 'Enter', flex: 2),
    ],
    <_KeySpec>[
      _KeySpec(LogicalKeyboardKey.keyZ, 'Z'),
      _KeySpec(LogicalKeyboardKey.keyX, 'X'),
      _KeySpec(LogicalKeyboardKey.keyC, 'C'),
      _KeySpec(LogicalKeyboardKey.keyV, 'V'),
      _KeySpec(LogicalKeyboardKey.keyB, 'B'),
      _KeySpec(LogicalKeyboardKey.keyN, 'N'),
      _KeySpec(LogicalKeyboardKey.keyM, 'M'),
      _KeySpec(LogicalKeyboardKey.delete, 'Del'),
    ],
    <_KeySpec>[
      _KeySpec(LogicalKeyboardKey.home, 'Home'),
      _KeySpec(LogicalKeyboardKey.pageUp, 'PgUp'),
      _KeySpec(LogicalKeyboardKey.pageDown, 'PgDn'),
      _KeySpec(LogicalKeyboardKey.end, 'End'),
      _KeySpec(LogicalKeyboardKey.space, 'Space', flex: 4),
      _KeySpec(LogicalKeyboardKey.arrowLeft, 'Lft'),
      _KeySpec(LogicalKeyboardKey.arrowUp, 'Up'),
      _KeySpec(LogicalKeyboardKey.arrowDown, 'Dn'),
      _KeySpec(LogicalKeyboardKey.arrowRight, 'Rgt'),
    ],
  ];

  static Set<LogicalKeyboardKey> get presentedKeys => <LogicalKeyboardKey>{
        for (final List<_KeySpec> row in _rows)
          for (final _KeySpec spec in row) spec.key,
      };

  @override
  Widget build(BuildContext context) {
    final ReverseBindingIndex index =
        ReverseBindingIndex.fromRegistry(registry, scope);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int maxFlex = _rows.fold<int>(
          1,
          (int acc, List<_KeySpec> row) {
            final int rowFlex =
                row.fold<int>(0, (int a, _KeySpec s) => a + s.flex);
            return rowFlex > acc ? rowFlex : acc;
          },
        );
        const double gap = 4;
        final double available =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 640;
        final double unit =
            ((available - gap * (maxFlex - 1)) / maxFlex).clamp(20.0, 56.0);

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final List<_KeySpec> row in _rows)
              Padding(
                padding: const EdgeInsets.only(bottom: gap),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    for (final _KeySpec spec in row)
                      Padding(
                        padding: const EdgeInsets.only(right: gap),
                        child: _buildCap(index, spec, unit, gap),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildCap(
    ReverseBindingIndex index,
    _KeySpec spec,
    double unit,
    double gap,
  ) {
    final bool bound = index.isKeyboardBound(spec.key);
    final List<ShortcutAction> actions = index.actionsForKey(spec.key);
    final VoidCallback? tap =
        (bound && onKeyTap != null) ? () => onKeyTap!(spec.key, actions) : null;
    final double width = unit * spec.flex + gap * (spec.flex - 1);

    return KeyCapWidget(
      key: Key('keycap_${spec.key.keyId}'),
      logicalKey: spec.key,
      label: spec.label,
      bound: bound,
      onTap: tap,
      width: width,
    );
  }
}
