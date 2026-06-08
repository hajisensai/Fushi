import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderStack;

import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

class ClipboardLookupTextPanel extends StatelessWidget {
  const ClipboardLookupTextPanel({
    required this.text,
    required this.onLookup,
    super.key,
  });

  final String text;
  final void Function(String query, Rect localRect) onLookup;

  @override
  Widget build(BuildContext context) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return const SizedBox.shrink();

    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<String> chars = trimmed.characters.toList(growable: false);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        0,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: HibikiCard(
        padding: EdgeInsets.all(tokens.spacing.gap),
        child: Wrap(
          spacing: 0,
          runSpacing: tokens.spacing.gap / 4,
          children: <Widget>[
            for (int i = 0; i < chars.length; i++)
              Builder(
                builder: (BuildContext charContext) {
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onLookup(
                      chars.skip(i).join(),
                      _localRectOf(context, charContext),
                    ),
                    child: Text(
                      chars[i],
                      style: tokens.type.listTitle.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  static Rect _localRectOf(
      BuildContext panelContext, BuildContext charContext) {
    final RenderObject? panel =
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
