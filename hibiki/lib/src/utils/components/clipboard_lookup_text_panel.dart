import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderStack;
import 'package:flutter/services.dart';

import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';

class ClipboardLookupTextPanel extends StatefulWidget {
  const ClipboardLookupTextPanel({
    required this.text,
    required this.onLookup,
    super.key,
    this.coordinateSpaceKey,
  });

  final String text;
  final void Function(String query, Rect localRect) onLookup;
  final GlobalKey? coordinateSpaceKey;

  @override
  State<ClipboardLookupTextPanel> createState() =>
      _ClipboardLookupTextPanelState();
}

class _ClipboardLookupTextPanelState extends State<ClipboardLookupTextPanel> {
  int? _lastShiftHoverIndex;

  @override
  Widget build(BuildContext context) {
    final String trimmed = widget.text.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<String> chars = trimmed.characters.toList(growable: false);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        0,
        tokens.spacing.page,
        tokens.spacing.gap / 2,
      ),
      child: Wrap(
        spacing: 0,
        runSpacing: tokens.spacing.gap / 4,
        children: <Widget>[
          for (int i = 0; i < chars.length; i++)
            Builder(
              builder: (BuildContext charContext) {
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  onHover: (_) => _handleShiftHover(
                    i,
                    context,
                    charContext,
                  ),
                  onExit: (_) {
                    if (_lastShiftHoverIndex == i) {
                      _lastShiftHoverIndex = null;
                    }
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _lookupAt(i, context, charContext),
                    child: Text(
                      chars[i],
                      style: tokens.type.metadata.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  void _handleShiftHover(
    int index,
    BuildContext panelContext,
    BuildContext charContext,
  ) {
    if (!HardwareKeyboard.instance.isShiftPressed) {
      _lastShiftHoverIndex = null;
      return;
    }
    if (_lastShiftHoverIndex == index) return;
    _lastShiftHoverIndex = index;
    _lookupAt(index, panelContext, charContext);
  }

  void _lookupAt(
    int index,
    BuildContext panelContext,
    BuildContext charContext,
  ) {
    final String trimmed = widget.text.trim();
    widget.onLookup(
      trimmed.characters.skip(index).join(),
      _localRectOf(panelContext, charContext),
    );
  }

  Rect _localRectOf(BuildContext panelContext, BuildContext charContext) {
    final RenderObject? panel =
        widget.coordinateSpaceKey?.currentContext?.findRenderObject() ??
            charContext.findAncestorRenderObjectOfType<RenderStack>() ??
            panelContext.findRenderObject();
    final RenderObject? child = charContext.findRenderObject();
    if (panel is! RenderBox || child is! RenderBox || !child.hasSize) {
      return Rect.zero;
    }
    final Offset global = child.localToGlobal(Offset.zero);
    return panel.globalToLocal(global) & child.size;
  }
}
