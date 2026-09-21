/// 一条发布在**订阅语义**下的范围：它是「某一集」还是「一整包」。
///
/// 这个判据此前散在三处各写一份（订阅服务内部的 `_looksLikeBatch`、版本卡的
/// `isLikelyBatchVideoRelease`、旧 nyaa 栈的 `NyaaTorrent.isBatch`），而真正致命
/// 的是**创建订阅的 UI 一处都没调用**：用户从一个全集包建订阅，规则照样按「追更
/// 单集」落库，检查时又在服务端被合集判据丢掉，于是生成一条结构上永不命中的订阅，
/// 界面只说「还没有跟踪到任何发布」（BUG-2619）。
///
/// 所以判据收在引擎这一处，创建端与检查端共用同一个答案：UI 拿它决定订阅该用
/// 一次性还是追更模式，服务端拿它决定候选落成哪种逻辑条目。
library;

import 'package:fushi_engine/media/video/video_filename_parser.dart';

/// 追更订阅里，一整包发布共用的逻辑条目键。
///
/// 追更按 `S01E05` 这类每集唯一的键去重，整包没有集号可用；一条一次性订阅整个
/// 生命周期里只认领这一个条目，所以固定键就够，且能让「同一包重复出现」天然幂等。
const String kBatchSubscriptionItemKey = 'batch';

/// 一条发布是不是整包（合集 / 整季 / 全集）。
///
/// 判据保守，全部对应真实发布形态：
/// - 显式关键词：batch / complete / season pack / 合集 / 全集；
/// - 带界定符的集数区间：`[01-12]` / `第01-12话` / `(01~24 Fin)` / `E01-E12` ——
///   要求区间由 第/括号/`E`/`EP` 引导**或**以 话/集/END/Fin/完 收尾，两端 1..300
///   且递增，避免把 `2023-08` 日期、分辨率误判成区间。
///
/// 注意它**认不出**只带 `[Fin]`、`BDRip` 这类没有区间也没有关键词的整季包——那种
/// 形态只能靠「解析不出集号」兜住，见 [subscriptionReleaseIsBatch]。
bool looksLikeBatchVideoRelease(String title) {
  if (RegExp(
    r'\b(batch|complete)\b',
    caseSensitive: false,
  ).hasMatch(title)) {
    return true;
  }
  if (RegExp('season pack', caseSensitive: false).hasMatch(title)) return true;
  if (title.contains('合集') || title.contains('全集')) return true;
  for (final RegExpMatch match in RegExp(
    // `E01-E12` / `EP01-EP24`：整季包的常见英文写法，两端都没有中文界定符也没有
    // 收尾词。删掉服务端私有判据后若不认这一形态，它会被 `parseVideoFilename`
    // 解析成「第 1 集」，追更订阅把 12/24 集的包当成一集入队并占掉 S01E01。
    // `\b` 前导避免吃到 `HEVC 10-bit` / `x264` 里的字母。
    r'(?:(?<lead>第|\[|\(|【|（|\b[Ee][Pp]?)\s*)?(\d{1,3})\s*[-~〜]\s*'
    r'(?:[Ee][Pp]?)?(\d{1,3})\s*'
    r'(?<tail>话|話|集|END|Fin|完)?',
    caseSensitive: false,
  ).allMatches(title)) {
    if (match.namedGroup('lead') == null && match.namedGroup('tail') == null) {
      continue;
    }
    final int? first = int.tryParse(match.group(2)!);
    final int? last = int.tryParse(match.group(3)!);
    if (first == null || last == null) continue;
    if (first >= 1 && last <= 300 && last > first) return true;
  }
  return false;
}

/// 这条发布在订阅语义下是否**不能**当成「某一集」。
///
/// 两种情况都归到整包：显式的合集形态（[looksLikeBatchVideoRelease]），以及解析
/// 不出集号的形态。后者是关键的一条：`[DMG&VCB-Studio] Revue Starlight 10-bit
/// 1080p HEVC BDRip [Fin]` 这种 BD 全集包既没有区间也没有关键词，只有「没有集号」
/// 这一个特征；而对追更订阅来说，「认不出集号」与「是整包」的后果完全一样——
/// 都不可能生成逐集条目。判据因此只按后果分类，不按标题长相分类。
///
/// 季号存在与否不参与判断：整季包与单集都可能带季号。
bool subscriptionReleaseIsBatch(String title) {
  if (looksLikeBatchVideoRelease(title)) return true;
  final VideoNameInfo parsed = parseVideoFilename(title);
  final int? episode = parsed.episode;
  return episode == null || episode <= 0;
}
