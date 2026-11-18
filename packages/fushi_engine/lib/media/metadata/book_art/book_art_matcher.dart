/// 书 / 漫画系列 ↔ 外部系列（MangaBaka / Bangumi）的匹配判据（纯函数，无 IO）。
///
/// 对**全部候选**打分，不取搜索第一条：实测 MangaBaka 搜索第一条约 13% 不对，分两类——
/// - 同名衍生作排在前（搜「呪術廻戦」第一条是 `呪術廻戦≡`，只有 3 卷）：靠卷号覆盖率
///   与 `final_volume` 认出；
/// - 装饰字符造成的近名（搜「citrus」第一条是 `citrus+`）：标题比较的通用归一化
///   （`TitleNormalizer`）把 `+ △ × ・` 当装饰删掉，两者完全相等。这里另有**严格**
///   归一化，保留 `+ ≡ △ × ☆`，只去分隔标点与空白。
///
/// 判定分三档（[BookArtDecision]）：自动采用 / 待确认 / 拒绝。批量入口只认自动采用。
///
/// 作者校验的现实约束：MangaBaka 的 `authors` 是罗马字（`Gege Akutami`），本地 EPUB
/// 作者通常是日文（`芥見下々`），两种书写无法比较时记 [BookArtAuthorEvidence.unknown]，
/// 不当成「对不上」；能比较（同为拉丁字母 / 同为 CJK，如 Bangumi infobox 的日文作者）
/// 而对不上才判拒。作者无法比较时自动采用要求多卷证据（本地 ≥2 个不同卷号全部覆盖），
/// 单卷最多到待确认。
library;

/// 本地书的种类提示（来自 `epub_books.format`）。
enum BookArtLocalKind {
  /// `format = manga`：确定是漫画。
  manga,

  /// `format = epub`：多半是文字书，但 BookWalker / Kindle 的日版漫画 EPUB 也是它。
  text,

  /// `format = pdf` 等：判不出。
  unknown,
}

/// 外部系列的种类。
enum BookArtCandidateKind { manga, novel, other }

/// MangaBaka `type` → 种类。
BookArtCandidateKind mangaBakaKind(String type) => switch (type) {
  'manga' ||
  'manhwa' ||
  'manhua' ||
  'oel' ||
  'one_shot' => BookArtCandidateKind.manga,
  'novel' || 'light_novel' => BookArtCandidateKind.novel,
  _ => BookArtCandidateKind.other,
};

/// Bangumi 书籍条目 `platform` → 种类。
BookArtCandidateKind bangumiKind(String? platform) => switch (platform) {
  '漫画' => BookArtCandidateKind.manga,
  '小说' || '轻小说' => BookArtCandidateKind.novel,
  _ => BookArtCandidateKind.other,
};

/// 标题档位（分数只用于排序）。
enum BookArtTitleTier {
  /// 严格归一化后相等。
  strict(1.0),

  /// 候选 = 本地系列名 + 分隔符 + 副标题（`キノの旅-the Beautiful World-`）。
  prefixSubtitle(0.8),

  /// 只有宽松归一化相等（`citrus` / `citrus+`）。
  loose(0.7),

  /// 本地系列名 = 候选 + 分隔符 + 副标题：本地可能是外传，最多待确认。
  localExtends(0.6),

  /// 对不上（含带衍生作品词的副标题）。
  none(0);

  const BookArtTitleTier(this.score);
  final double score;

  bool get canAutoAccept => this == strict || this == prefixSubtitle;
}

enum BookArtAuthorEvidence { match, mismatch, unknown }

enum BookArtDecision { accepted, needsConfirm, rejected }

/// 一个本地系列（同 `parseBookSeriesKey` 键的分卷）。
class BookArtLocalSeries {
  const BookArtLocalSeries({
    required this.seriesTitle,
    required this.kind,
    required this.volumes,
    this.author,
    this.singleUnnumbered = false,
  });

  /// 系列名（`BookSeriesKey.seriesTitle`）。
  final String seriesTitle;
  final BookArtLocalKind kind;

  /// 本地各卷卷号（已按 [resolveLocalVolumes] 解析；配不出卷号的书不在内）。
  final List<num> volumes;
  final String? author;

  /// 系列只有一本、且标题没写卷号（按第 1 卷尝试，证据要求更严）。
  final bool singleUnnumbered;
}

/// 一个外部系列候选（与源无关的比较面）。
class BookArtCandidate {
  const BookArtCandidate({
    required this.source,
    required this.id,
    required this.displayTitle,
    required this.titles,
    required this.kind,
    this.authors = const <String>[],
    this.finalVolume,
    this.isAdult = false,
  });

  /// `mangabaka` / `bangumi`。
  final String source;
  final String id;
  final String displayTitle;
  final List<String> titles;
  final BookArtCandidateKind kind;
  final List<String> authors;
  final num? finalVolume;
  final bool isAdult;
}

/// 不联网就能做的那部分评估（标题 / 种类 / 作者）。
class BookArtTitleAssessment {
  const BookArtTitleAssessment({
    required this.tier,
    required this.kindCompatible,
    required this.kindPreferred,
    required this.author,
  });

  final BookArtTitleTier tier;

  /// 种类不冲突（漫画书配到小说系列 = 冲突）。
  final bool kindCompatible;

  /// 种类就是本地最可能的那种（文字 EPUB → 小说；漫画 → 漫画）。
  final bool kindPreferred;
  final BookArtAuthorEvidence author;

  /// 值得拉卷列表做覆盖率校验。
  bool get worthVolumeCheck =>
      tier != BookArtTitleTier.none &&
      kindCompatible &&
      author != BookArtAuthorEvidence.mismatch;
}

/// 一个候选的完整评估结果。
class BookArtScoredCandidate {
  const BookArtScoredCandidate({
    required this.candidate,
    required this.assessment,
    required this.coverage,
    required this.finalVolumeOk,
    required this.autoEligible,
    required this.titleAutoOk,
    required this.score,
  });

  final BookArtCandidate candidate;
  final BookArtTitleAssessment assessment;

  /// 本地卷号被候选卷封面覆盖的比例（0..1）。
  final double coverage;

  /// `final_volume` 不小于本地最大卷号（或源站没给）。
  final bool finalVolumeOk;
  final bool autoEligible;

  /// 标题档本身允许自动采用：严格同名，或「前缀 + 副标题」且候选里没有严格同名的
  /// 系列（有严格同名时同名衍生作最多待确认）。Bangumi 补卷也要过这一关。
  final bool titleAutoOk;

  /// 排序分（标题 0.5 + 覆盖率 0.3 + 种类 0.1 + 作者 0.1）。
  final double score;
}

/// 一次系列匹配的结论：[best] 是排序第一的可用候选（拒绝时为 null）。
class BookArtMatchResult {
  const BookArtMatchResult({
    required this.decision,
    required this.ranked,
    this.reason,
  });

  final BookArtDecision decision;

  /// 未被拒绝的候选，按分从高到低。
  final List<BookArtScoredCandidate> ranked;

  /// 降档原因（日志 / 结果摘要用，英文短语）。
  final String? reason;

  BookArtScoredCandidate? get best => ranked.isEmpty ? null : ranked.first;
}

// ── 归一化 ─────────────────────────────────────────────────────────────

/// 全角 ASCII → 半角、全角空格 → 空格。
String foldBookArtWidth(String s) => String.fromCharCodes(<int>[
  for (final int c in s.runes)
    c >= 0xFF01 && c <= 0xFF5E
        ? c - 0xFEE0
        : c == 0x3000
        ? 0x20
        : c,
]);

/// 分隔类标点：严格比较时删掉，判「前缀 + 副标题」时当分隔符。
const String _separators =
    ' \t・·、。,.:;!?\'"`-‐‑–—―~〜～/\\|()[]{}<>「」『』【】〈〉《》〔〕…';

/// 装饰字符：严格比较**保留**（`citrus+` ≠ `citrus`），宽松比较删掉。
const String _decorations = '+≡△×☆★♪♡♥◆◇○●';

bool _isSeparator(int rune) => _separators.runes.contains(rune);

/// 严格归一化：折宽、小写、去空白与分隔标点，保留 `+ ≡ △ × ☆` 等装饰字符。
String strictBookTitleKey(String title) {
  final String folded = foldBookArtWidth(title).toLowerCase();
  final StringBuffer out = StringBuffer();
  for (final int r in folded.runes) {
    if (_isSeparator(r) || r == 0x3000 || r <= 0x20) continue;
    out.writeCharCode(r);
  }
  return out.toString();
}

/// 宽松归一化：严格归一化后再删装饰字符。
String looseBookTitleKey(String title) {
  final StringBuffer out = StringBuffer();
  for (final int r in strictBookTitleKey(title).runes) {
    if (_decorations.runes.contains(r)) continue;
    out.writeCharCode(r);
  }
  return out.toString();
}

/// 副标题里出现即判「衍生作品」的词（本地系列名里也有时不算）。CJK 词按子串比，
/// 拉丁词按整词比（`ss` 不吃掉 `class`）；比较在折宽小写后的串上做。
const List<String> kBookArtDerivativeWords = <String>[
  'アンソロジー',
  'anthology',
  '外伝',
  '番外',
  'ss',
  'dj',
  'doujinshi',
  'プログレッシブ',
  'progressive',
  '公式',
  'ガイド',
  'guide',
  'ファンブック',
  'fanbook',
  '画集',
  'artbook',
  'artworks',
  'イラスト集',
  '≡',
  '創約',
  'ノベライズ',
  'novelization',
  '劇場版',
  'スピンオフ',
  'spin-off',
  'spinoff',
  'コミカライズ',
  '短編集',
  'bonus',
];

bool _containsDerivativeWord(String light, String word) {
  if (!_latin.hasMatch(word)) return light.contains(word);
  return RegExp(
    '(?<![a-z0-9])${RegExp.escape(word)}(?![a-z0-9])',
  ).hasMatch(light);
}

bool _hasDerivativeWord(String remainderLight, String localLight) {
  for (final String w in kBookArtDerivativeWords) {
    if (_containsDerivativeWord(remainderLight, w) &&
        !_containsDerivativeWord(localLight, w)) {
      return true;
    }
  }
  return false;
}

/// 轻度归一化（折宽、小写、空白折叠），保留分隔符以判前缀边界。
String _lightKey(String s) =>
    foldBookArtWidth(s).toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

/// [local] 与 [remote] 一个写法的标题档位。
BookArtTitleTier compareBookTitles(String local, String remote) {
  final String ls = strictBookTitleKey(local);
  final String rs = strictBookTitleKey(remote);
  if (ls.isEmpty || rs.isEmpty) return BookArtTitleTier.none;
  if (ls == rs) return BookArtTitleTier.strict;
  final String ll = _lightKey(local);
  final String rl = _lightKey(remote);
  final BookArtTitleTier? prefix = _prefixTier(ll, rl, ll, forward: true);
  if (prefix != null) return prefix;
  final BookArtTitleTier? reverse = _prefixTier(rl, ll, ll, forward: false);
  if (reverse != null) return reverse;
  if (looseBookTitleKey(local).isNotEmpty &&
      looseBookTitleKey(local) == looseBookTitleKey(remote)) {
    return BookArtTitleTier.loose;
  }
  return BookArtTitleTier.none;
}

/// [longer] 以 [shorter] 开头且紧跟分隔符 → 前缀档；副标题带衍生作品词 → none。
BookArtTitleTier? _prefixTier(
  String shorter,
  String longer,
  String localLight, {
  required bool forward,
}) {
  if (shorter.isEmpty || longer.length <= shorter.length) return null;
  if (!longer.startsWith(shorter)) return null;
  // startsWith 已保证代码单元下标 shorter.length 落在 shorter 的结尾边界上，
  // 且 longer 更长 → 余下部分非空，不必按码点计数。
  final String remainderLight = longer.substring(shorter.length);
  if (!_isSeparator(remainderLight.runes.first)) return null;
  if (strictBookTitleKey(remainderLight).isEmpty) {
    return BookArtTitleTier.strict;
  }
  if (forward && _hasDerivativeWord(remainderLight, localLight)) {
    return BookArtTitleTier.none;
  }
  return forward
      ? BookArtTitleTier.prefixSubtitle
      : BookArtTitleTier.localExtends;
}

/// [local] 对候选全部写法取最好的档位。
///
/// [remotes] 的第一项是候选的原名（MangaBaka `native_title` / Bangumi `name`）：原名
/// 只到宽松档（原名是装饰变体，如 `citrus+`）时，别名再像也封顶宽松档——`citrus+`
/// 的英文别名 `Citrus Plus` 不能把它抬成「citrus + 副标题」。
BookArtTitleTier bestTitleTier(String local, Iterable<String> remotes) {
  BookArtTitleTier best = BookArtTitleTier.none;
  BookArtTitleTier? primary;
  for (final String r in remotes) {
    final BookArtTitleTier tier = compareBookTitles(local, r);
    primary ??= tier;
    if (tier.score > best.score) best = tier;
    if (best == BookArtTitleTier.strict) break;
  }
  if (primary == BookArtTitleTier.loose) return BookArtTitleTier.loose;
  return best;
}

// ── 作者 ───────────────────────────────────────────────────────────────

final RegExp _cjk = RegExp(r'[぀-ヿ㐀-鿿豈-﫿]');
final RegExp _latin = RegExp(r'[a-zA-Z]');
final RegExp _authorSplit = RegExp(r'\s*[,，、/／&;；]\s*|\s+(?:and|x)\s+');

List<String> _authorNames(String raw) => <String>[
  for (final String part in raw.split(_authorSplit))
    if (part.trim().isNotEmpty)
      part.replaceAll(RegExp(r'[(（][^)）]*[)）]'), '').trim(),
];

/// 拉丁名按词集合比（`Gege Akutami` == `Akutami Gege`），CJK 名去空白与「・」后比。
String _authorKey(String name) {
  final String folded = foldBookArtWidth(name).toLowerCase();
  if (_cjk.hasMatch(folded)) {
    return folded.replaceAll(RegExp(r'[\s・·=＝]'), '');
  }
  final List<String> words =
      folded
          .split(RegExp(r'[^a-z0-9]+'))
          .where((String w) => w.isNotEmpty)
          .toList()
        ..sort();
  return words.join(' ');
}

/// 本地作者 [local] 与候选作者 [remote] 的证据。
BookArtAuthorEvidence compareBookAuthors(String? local, List<String> remote) {
  if (local == null || local.trim().isEmpty || remote.isEmpty) {
    return BookArtAuthorEvidence.unknown;
  }
  final List<String> mine = _authorNames(local);
  final List<String> theirs = <String>[
    for (final String r in remote) ..._authorNames(r),
  ];
  bool comparable = false;
  for (final String a in mine) {
    final bool aCjk = _cjk.hasMatch(a);
    final bool aLatin = !aCjk && _latin.hasMatch(a);
    for (final String b in theirs) {
      final bool bCjk = _cjk.hasMatch(b);
      final bool bLatin = !bCjk && _latin.hasMatch(b);
      if ((aCjk && bCjk) || (aLatin && bLatin)) {
        comparable = true;
        final String ka = _authorKey(a);
        final String kb = _authorKey(b);
        if (ka.isNotEmpty &&
            (ka == kb ||
                (aCjk &&
                    (ka.contains(kb) || kb.contains(ka)) &&
                    kb.isNotEmpty))) {
          return BookArtAuthorEvidence.match;
        }
      }
    }
  }
  return comparable
      ? BookArtAuthorEvidence.mismatch
      : BookArtAuthorEvidence.unknown;
}

// ── 评估与判定 ─────────────────────────────────────────────────────────

/// 不联网评估一个候选。
BookArtTitleAssessment assessBookArtCandidate(
  BookArtLocalSeries local,
  BookArtCandidate candidate,
) {
  final bool compatible = switch (local.kind) {
    BookArtLocalKind.manga => candidate.kind == BookArtCandidateKind.manga,
    BookArtLocalKind.text ||
    BookArtLocalKind.unknown => candidate.kind != BookArtCandidateKind.other,
  };
  final bool preferred = switch (local.kind) {
    BookArtLocalKind.manga => candidate.kind == BookArtCandidateKind.manga,
    BookArtLocalKind.text => candidate.kind == BookArtCandidateKind.novel,
    BookArtLocalKind.unknown => false,
  };
  return BookArtTitleAssessment(
    tier: bestTitleTier(local.seriesTitle, candidate.titles),
    kindCompatible: compatible,
    kindPreferred: preferred,
    author: compareBookAuthors(local.author, candidate.authors),
  );
}

/// 卷号相等的容差（`28.5`、`1.1` 这类小数卷）。
const double kBookArtVolumeTolerance = 0.01;

/// [indexes] 里是否有与 [volume] 相等的卷号。
bool bookArtHasVolume(Iterable<num> indexes, num volume) =>
    indexes.any((num i) => (i - volume).abs() < kBookArtVolumeTolerance);

/// 本地卷号被 [indexes] 覆盖的比例；本地没有卷号为 0。
double bookArtCoverage(List<num> local, Iterable<num> indexes) {
  if (local.isEmpty) return 0;
  final int hit = local.where((num v) => bookArtHasVolume(indexes, v)).length;
  return hit / local.length;
}

/// 把评估过、拉过卷号集合的候选合成结论。
///
/// [volumeIndexes] 以候选 id 为键；没拉卷列表的候选（标题就不行）可缺省。
/// [linkedId]：追踪映射里 `auto` 来源的系列 id——结论不是它时降为待确认（以追踪
/// 链接为准，不各存各的）。`manual` / `id` / `suggestion` 链接由调用方直接采用，不进
/// 这里。
BookArtMatchResult decideBookArtMatch({
  required BookArtLocalSeries local,
  required List<BookArtCandidate> candidates,
  required Map<String, Set<num>> volumeIndexes,
  String? linkedId,
}) {
  final List<num> volumes = local.volumes;
  final num? maxVolume = volumes.isEmpty
      ? null
      : volumes.reduce((num a, num b) => a > b ? a : b);
  // 同一卷的通常版 / 特装版各算一本时不重复计数：作者放宽规则看的是「几卷」。
  final List<num> distinctVolumes = <num>[];
  for (final num v in volumes) {
    if (!bookArtHasVolume(distinctVolumes, v)) distinctVolumes.add(v);
  }
  // 候选里有严格同名的（且种类不冲突）：「前缀 + 副标题」的只能待确认——主系列可能
  // 只是没有日文卷封面（覆盖率 0 被丢），不能让同名衍生作趁机被自动采用。
  final bool strictExists = candidates.any((BookArtCandidate c) {
    final BookArtTitleAssessment a = assessBookArtCandidate(local, c);
    return a.tier == BookArtTitleTier.strict && a.kindCompatible;
  });
  final List<BookArtScoredCandidate> scored = <BookArtScoredCandidate>[];
  for (final BookArtCandidate c in candidates) {
    final BookArtTitleAssessment a = assessBookArtCandidate(local, c);
    if (!a.worthVolumeCheck) continue;
    final Set<num> indexes = volumeIndexes[c.id] ?? const <num>{};
    final double coverage = bookArtCoverage(volumes, indexes);
    final num? fv = c.finalVolume;
    final bool finalOk =
        fv == null ||
        maxVolume == null ||
        fv + kBookArtVolumeTolerance >= maxVolume;
    final bool authorOk =
        a.author == BookArtAuthorEvidence.match ||
        (a.author == BookArtAuthorEvidence.unknown &&
            distinctVolumes.length >= 2);
    final bool singleOk =
        !local.singleUnnumbered ||
        (a.tier == BookArtTitleTier.strict &&
            a.author == BookArtAuthorEvidence.match &&
            (fv == 1 || (indexes.length == 1 && bookArtHasVolume(indexes, 1))));
    final bool titleAuto =
        a.tier == BookArtTitleTier.strict ||
        (a.tier == BookArtTitleTier.prefixSubtitle && !strictExists);
    final bool auto =
        titleAuto &&
        a.kindPreferred &&
        coverage >= 1 &&
        finalOk &&
        !c.isAdult &&
        authorOk &&
        singleOk;
    // 单本无卷号：严格条件不满足就不配（外传 / 画集 / 短篇集常是无卷号单本）。
    if (local.singleUnnumbered && !singleOk) continue;
    if (!auto && coverage < 0.5) continue;
    scored.add(
      BookArtScoredCandidate(
        candidate: c,
        assessment: a,
        coverage: coverage,
        finalVolumeOk: finalOk,
        autoEligible: auto,
        titleAutoOk: titleAuto,
        score:
            a.tier.score * 0.5 +
            coverage * 0.3 +
            (a.kindPreferred ? 0.1 : 0) +
            (a.author == BookArtAuthorEvidence.match ? 0.1 : 0),
      ),
    );
  }
  scored.sort((BookArtScoredCandidate x, BookArtScoredCandidate y) {
    if (x.autoEligible != y.autoEligible) return x.autoEligible ? -1 : 1;
    return y.score.compareTo(x.score);
  });
  if (scored.isEmpty) {
    return const BookArtMatchResult(
      decision: BookArtDecision.rejected,
      ranked: <BookArtScoredCandidate>[],
      reason: 'no trustworthy candidate',
    );
  }
  final int autoCount = scored.where((s) => s.autoEligible).length;
  if (autoCount == 1) {
    if (linkedId != null && scored.first.candidate.id != linkedId) {
      return BookArtMatchResult(
        decision: BookArtDecision.needsConfirm,
        ranked: scored,
        reason: 'differs from tracking link $linkedId',
      );
    }
    return BookArtMatchResult(
      decision: BookArtDecision.accepted,
      ranked: scored,
    );
  }
  return BookArtMatchResult(
    decision: BookArtDecision.needsConfirm,
    ranked: scored,
    reason: autoCount > 1
        ? 'several candidates qualify'
        : _whyNotAuto(scored.first, local),
  );
}

String _whyNotAuto(BookArtScoredCandidate s, BookArtLocalSeries local) {
  if (!s.assessment.tier.canAutoAccept) return 'title is only a near match';
  if (s.assessment.tier != BookArtTitleTier.strict) {
    return 'an exact-title series also exists';
  }
  if (!s.assessment.kindPreferred) return 'type differs from the local book';
  if (s.candidate.isAdult) return 'adult series';
  if (s.coverage < 1) return 'not every local volume is covered';
  if (!s.finalVolumeOk) return 'final volume is below the local volumes';
  return 'author cannot be confirmed';
}

/// 本地一个系列的分卷 → 卷号。
///
/// [titleVolumes] 是各本书标题解析出的卷号（`parseBookSeriesKey(...).volume`，没写
/// 卷号为 null），键是书的身份。**不用合集内序号兜底**（按序号配封面会贴错）：
/// - 写了卷号的照用；
/// - 系列 ≥2 本、恰好一本没写卷号、且没有别的卷自称第 1 卷 → 它是第 1 卷（与
///   `collectionMemberVolumeNumber` 同一判据）；
/// - 系列只有它一本、没写卷号 → 第 1 卷，但 [BookArtLocalSeries.singleUnnumbered]
///   为真，匹配要求更严；
/// - 其余没卷号的书不配封面（不在返回值里）。
({Map<String, num> volumes, bool singleUnnumbered}) resolveLocalVolumes(
  Map<String, num?> titleVolumes,
) {
  final Map<String, num> out = <String, num>{};
  final List<String> unnumbered = <String>[];
  titleVolumes.forEach((String key, num? v) {
    if (v == null) {
      unnumbered.add(key);
    } else {
      out[key] = v;
    }
  });
  if (titleVolumes.length == 1 && unnumbered.length == 1) {
    return (
      volumes: <String, num>{unnumbered.single: 1},
      singleUnnumbered: true,
    );
  }
  if (unnumbered.length == 1 && !bookArtHasVolume(out.values, 1)) {
    out[unnumbered.single] = 1;
  }
  return (volumes: out, singleUnnumbered: false);
}
