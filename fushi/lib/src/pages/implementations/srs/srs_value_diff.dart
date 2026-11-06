/// 冲突中心两边内容的差异对比：按字符求最长公共子序列，被替换的一边独有的字划掉、当前生效的一边独有的字高亮。
/// 只对两段都不长的文本做（[kSrsDiffMaxChars]）；太长或不是文本的值只并排显示两边，不画差异。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';

/// 做差异的单边长度上限（字符；LCS 是 O(n·m)）。
const int kSrsDiffMaxChars = 600;

enum SrsDiffOp { same, removed, added }

/// [from] → [to] 的字符级差异（相邻同类合并成一段）。任一边超过 [kSrsDiffMaxChars] 返回 null。
List<(SrsDiffOp, String)>? srsDiffSegments(String from, String to) {
  final List<int> a = from.runes.toList();
  final List<int> b = to.runes.toList();
  if (a.length > kSrsDiffMaxChars || b.length > kSrsDiffMaxChars) return null;
  final int n = a.length;
  final int m = b.length;
  // lcs[i][j] = a[i..] 与 b[j..] 的 LCS 长度（一维展开）。
  final List<int> lcs = List<int>.filled((n + 1) * (m + 1), 0);
  int at(int i, int j) => i * (m + 1) + j;
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      lcs[at(i, j)] = a[i] == b[j]
          ? lcs[at(i + 1, j + 1)] + 1
          : (lcs[at(i + 1, j)] >= lcs[at(i, j + 1)]
                ? lcs[at(i + 1, j)]
                : lcs[at(i, j + 1)]);
    }
  }
  final List<(SrsDiffOp, String)> out = <(SrsDiffOp, String)>[];
  void push(SrsDiffOp op, int rune) {
    final String ch = String.fromCharCode(rune);
    if (out.isNotEmpty && out.last.$1 == op) {
      out[out.length - 1] = (op, out.last.$2 + ch);
    } else {
      out.add((op, ch));
    }
  }

  int i = 0;
  int j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      push(SrsDiffOp.same, a[i]);
      i++;
      j++;
    } else if (lcs[at(i + 1, j)] >= lcs[at(i, j + 1)]) {
      push(SrsDiffOp.removed, a[i++]);
    } else {
      push(SrsDiffOp.added, b[j++]);
    }
  }
  while (i < n) {
    push(SrsDiffOp.removed, a[i++]);
  }
  while (j < m) {
    push(SrsDiffOp.added, b[j++]);
  }
  return out;
}

/// 差异块：「差异」小标题 + 一段富文本（划掉 = 只在被替换的一边，高亮 = 只在当前生效的一边）。
class SrsValueDiff extends StatelessWidget {
  const SrsValueDiff({super.key, required this.from, required this.to});

  /// 被替换的一边。
  final String from;

  /// 当前生效的一边。
  final String to;

  @override
  Widget build(BuildContext context) {
    final List<(SrsDiffOp, String)>? segs = srsDiffSegments(from, to);
    if (segs == null || from == to) return const SizedBox.shrink();
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle base = context.fushiType.bodyMedium;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Container(
      key: const ValueKey<String>('srs-conflict-diff'),
      padding: EdgeInsets.all(tokens.spacing.gap),
      decoration: BoxDecoration(
        // 差异块嵌在冲突卡（FushiCard）里：取「分组里再嵌一层」的面板色与卡内小件圆角，
        // MD3 / Apple / 玻璃三套色阶由设计令牌分派，这里不自选色调。
        color: tokens.surfaces.card,
        borderRadius: tokens.radii.cardRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: tokens.spacing.gap / 2,
        children: <Widget>[
          Text(t.srs_conflict_diff, style: tokens.type.sectionLabel),
          Text.rich(
            TextSpan(
              style: base,
              children: <InlineSpan>[
                for (final (SrsDiffOp op, String text) in segs)
                  TextSpan(
                    text: text,
                    style: switch (op) {
                      SrsDiffOp.same => null,
                      SrsDiffOp.removed => TextStyle(
                        color: cs.error,
                        decoration: TextDecoration.lineThrough,
                        decorationColor: cs.error,
                      ),
                      SrsDiffOp.added => TextStyle(
                        color: cs.onPrimaryContainer,
                        backgroundColor: cs.primaryContainer,
                      ),
                    },
                  ),
              ],
            ),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
