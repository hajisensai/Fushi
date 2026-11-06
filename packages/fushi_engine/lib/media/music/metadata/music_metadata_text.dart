/// 音乐元数据比对用的文本归一化（标签 ↔ MusicBrainz）。
///
/// 只用于**判定是否同一首**，不用于显示。规则：全角 ASCII → 半角、小写、只留字母与数字
/// （CJK / 假名都是 `\p{L}`，保留）。
library;

final RegExp _keep = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// 归一化：`「Lemon」` / `ＬＥＭＯＮ` / `lemon!` → `lemon`。
String normalizeMusicText(String input) {
  final StringBuffer out = StringBuffer();
  for (final int rune in input.runes) {
    int r = rune;
    if (r >= 0xFF01 && r <= 0xFF5E) r -= 0xFEE0; // 全角 ASCII
    final String ch = String.fromCharCode(r).toLowerCase();
    if (_keep.hasMatch(ch)) out.write(ch);
  }
  return out.toString();
}

/// 版本注记：结尾的括号段（`(TV size)` / `[Remastered]` / `（off vocal）` / `【MV】`）与
/// ` - xxx` / `～xxx～` 后缀。
final RegExp _trailingAnnotation = RegExp(
  r'(\s*(\([^()]*\)|\[[^\[\]]*\]|（[^（）]*）|【[^【】]*】|〔[^〔〕]*〕|～[^～]*～|~[^~]*~)\s*)+$'
  r'|\s+[-–—]\s+[^-–—]+$',
);

/// 去掉结尾版本注记后的标题（`Lemon (Remastered)` → `Lemon`）。全是注记时原样返回。
String stripMusicTitleAnnotations(String title) {
  final String stripped = title.replaceFirst(_trailingAnnotation, '').trim();
  return stripped.isEmpty ? title.trim() : stripped;
}

/// 标题相似度：归一化后相等 1.0；去版本注记后相等 0.8；否则 0。
double musicTitleSimilarity(String a, String b) {
  final String na = normalizeMusicText(a);
  final String nb = normalizeMusicText(b);
  if (na.isEmpty || nb.isEmpty) return 0;
  if (na == nb) return 1;
  final String sa = normalizeMusicText(stripMusicTitleAnnotations(a));
  final String sb = normalizeMusicText(stripMusicTitleAnnotations(b));
  if (sa.isNotEmpty && sa == sb) return 0.8;
  return 0;
}

/// 艺人分隔符（标签里常把多位艺人写进一个字段）。
final RegExp _artistSeparators = RegExp(
  r'\s*(?:,|、|，|/|／|;|；|&|＆|×|\bx\b|\bfeat\.?|\bft\.?|\bwith\b|\bvs\.?)\s*',
  caseSensitive: false,
);

/// 拆成单个艺人名（已归一化、去空）。
Set<String> splitMusicArtists(String credit) => <String>{
  for (final String part in credit.split(_artistSeparators))
    if (normalizeMusicText(part) case final String n when n.isNotEmpty) n,
};

/// 声优标注：`ノア(CV:鈴代紗弓)` / `生塩ノア（CV.鈴代紗弓）` / `アロナ (cv.小原好美)`。
final RegExp _cvPart = RegExp(
  r'[(（]\s*cv\s*[.:：．]?\s*([^)）]+)[)）]',
  caseSensitive: false,
  unicode: true,
);

/// 片假名 → 平假名（`サオリ` 与 `さおり` 同名）。只用于艺人比对。
String _foldKana(String s) => String.fromCharCodes(<int>[
  for (final int r in s.runes) (r >= 0x30A1 && r <= 0x30F6) ? r - 0x60 : r,
]);

/// 一个署名里的（角色名, 声优名）对：没有 CV 标注时角色名就是整串、声优为空。
List<({String name, Set<String> cv})> _artistEntries(String credit) {
  final List<({String name, Set<String> cv})> out =
      <({String name, Set<String> cv})>[];
  for (final String part in credit.split(_artistSeparators)) {
    final Set<String> cv = <String>{
      for (final RegExpMatch m in _cvPart.allMatches(part))
        for (final String n in splitMusicArtists(m.group(1)!)) _foldKana(n),
    };
    final String name = _foldKana(
      normalizeMusicText(part.replaceAll(_cvPart, '')),
    );
    if (name.isEmpty && cv.isEmpty) continue;
    out.add((name: name, cv: cv));
  }
  return out;
}

/// 艺人相似度：整串归一化相等 1.0；拆开后有交集 0.8；角色歌的同一声优（`(CV:…)` 里的名字
/// 相同）或角色名一方包含另一方（`ノア` ⊂ `生塩ノア`，≥ 2 字）0.8；否则 0。
double musicArtistSimilarity(String tag, Iterable<String> candidateNames) {
  final String nt = normalizeMusicText(tag);
  if (nt.isEmpty) return 0;
  final Set<String> tagParts = splitMusicArtists(tag);
  final List<({String name, Set<String> cv})> tagEntries = _artistEntries(tag);
  double best = 0;
  for (final String name in candidateNames) {
    final String nn = normalizeMusicText(name);
    if (nn.isEmpty) continue;
    if (nn == nt || _foldKana(nn) == _foldKana(nt)) return 1;
    final Set<String> parts = splitMusicArtists(name);
    if (parts.intersection(tagParts).isNotEmpty ||
        tagParts.contains(nn) ||
        parts.contains(nt)) {
      best = 0.8;
      continue;
    }
    for (final ({String name, Set<String> cv}) a in tagEntries) {
      for (final ({String name, Set<String> cv}) b in _artistEntries(name)) {
        final bool sameCv =
            a.cv.isNotEmpty && a.cv.intersection(b.cv).isNotEmpty;
        final bool nested =
            a.name.length >= 2 &&
            b.name.length >= 2 &&
            (a.name.contains(b.name) || b.name.contains(a.name));
        if (sameCv || (nested && (a.cv.isEmpty || b.cv.isEmpty || sameCv))) {
          best = 0.8;
        }
      }
    }
  }
  return best;
}

/// MusicBrainz 残缺日期的排序键：`2018` < `2018-02` < `2018-02-20`（缺月日当作该期起点）；
/// 没有日期排最后。
String musicDateSortKey(String? date) =>
    (date == null || date.trim().isEmpty) ? '9999' : date.trim();
