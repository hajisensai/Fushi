// 拍板台 rf--UcsGta-overlay（方案 b「转交主窗」）：应用外查词覆盖窗（Windows /
// macOS / X11 的原生 WebView 卡）点「高级制卡」时，把这个词条 + 抓到的上下文交给
// 主窗查词页，拉起主窗后在那里打开完整的高级制卡对话框。
//
// 为什么不在覆盖窗里弹：覆盖窗失焦即自关（前台钩子），app 外没有 Flutter 层可以
// 画对话框（overlay_bridge_handlers.dart 文件头）；在 WebView 里另做一套精简面板
// 是拍板台否掉的方案 a。转交走的是 #4284 已经铺好的主窗出口
// （[AppModel.queueExternalLookup] → 查词页结果区 + 抓取上下文句子分区）。
//
// 本文件只放纯数据与纯函数：覆盖窗那头解析桥参数、决定交给主窗哪段文本和哪份
// 上下文；主窗那头按词条身份（不是覆盖窗的下标）在自己的结果里找回同一个词条。

import 'package:fushi/src/lookup/captured_context_sentences.dart';
import 'package:fushi/src/lookup/global_lookup_stack.dart';

/// 覆盖窗卡片上被点「高级制卡」的那个词条的身份。
///
/// 不带覆盖窗里的词条下标：主窗重新查一遍，两边分页 / 渲染时机不同，下标对不上就会
/// 制错卡；主窗按这三项在自己的结果里找（popup.js `fushiPopupEntryDomIndexFor`）。
class AdvancedMiningHandoff {
  const AdvancedMiningHandoff({
    required this.expression,
    required this.reading,
    required this.matched,
  });

  /// 词条表记（popup.js 词条的 `expression`）。
  final String expression;

  /// 词条读音（可能为空）。
  final String reading;

  /// 查询串里命中这个词条的那一段（对话框标题与句子高亮用）。
  final String matched;

  /// 解析 popup.js `callHandler('openAdvancedMining', {entryIndex, matched,
  /// expression, reading})` 的参数（宿主收到的是 `args` 列表，首项是那个对象）。
  /// 没有表记的不算有效转交（主窗无从定位词条），返回 null。
  static AdvancedMiningHandoff? fromBridgeArgs(Object? args) {
    final Object? first = args is List && args.isNotEmpty ? args.first : null;
    if (first is! Map) return null;
    String field(String key) {
      final Object? value = first[key];
      return value == null ? '' : value.toString();
    }

    final String expression = field('expression').trim();
    if (expression.isEmpty) return null;
    return AdvancedMiningHandoff(
      expression: expression,
      reading: field('reading').trim(),
      matched: field('matched'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AdvancedMiningHandoff &&
      other.expression == expression &&
      other.reading == reading &&
      other.matched == matched;

  @override
  int get hashCode => Object.hash(expression, reading, matched);

  @override
  String toString() =>
      'AdvancedMiningHandoff(expression: $expression, reading: $reading, '
      'matched: $matched)';
}

/// 覆盖窗把哪段文本、哪份上下文交给主窗查词页。
typedef OverlayHandoffSource = ({
  String text,
  CapturedSentenceContext? capturedContext,
});

/// 按发起这次转交的卡层（host 盖在消息上的 `__frameId`）决定交给主窗的内容：
///
/// - 根卡：根查询串（用户在别的程序里选中的那段文字）+ 这次查词抓到的上下文。
///   有切好的前后句（[captured]，开了「抓取上下文」）就交它；只有一句（悬浮字幕 /
///   歌词行等表面给的 [sentence]）就包成没有前后句的上下文，主窗例句与覆盖窗「+」
///   制卡用的是同一句。
/// - 嵌套卡（从释义里点出来的词）：该层的查询串，不带上下文——那句话是根词的语境，
///   不是它的（与覆盖窗制卡口径一致）。
/// - 消息没带层 id 时按根卡算；带了但栈里已没有这一层（卡已关）返回 null，不转交。
OverlayHandoffSource? resolveOverlayHandoffSource({
  required GlobalLookupStack stack,
  required String? frameId,
  required CapturedSentenceContext? captured,
  required String sentence,
}) {
  final List<GlobalLookupFrame> frames = stack.frames;
  if (frames.isEmpty) return null;
  int index = 0;
  if (frameId != null) {
    index = frames.indexWhere((GlobalLookupFrame f) => f.id == frameId);
    if (index < 0) return null;
  }
  final String text = frames[index].query.trim();
  if (text.isEmpty) return null;
  if (index > 0) return (text: text, capturedContext: null);
  final String current = sentence.trim();
  final CapturedSentenceContext? context =
      captured ??
      (current.isEmpty
          ? null
          : CapturedSentenceContext(
              before: const <String>[],
              current: current,
              after: const <String>[],
            ));
  return (text: text, capturedContext: context);
}

/// 主窗结果区的 popup.js 回报「尾批词条还在分片渲染」（`_renderInProgress`），
/// 还不能定位词条：等下一次 `popupRendered` 再问。
const int kPopupEntryIndexStillRendering = -2;
