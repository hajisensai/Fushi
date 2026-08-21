/// 字幕**正文**语言检测（纯函数）。
///
/// 文件名标签（`[JPN]` / `[CHS]`）经常是错的——上传者复制模板、打包改名都会
/// 留下错标签；正文才是权威（参照 RSS-Subtitle-Manager 的同名判据）。本模块
/// 只看对白文本：ASS 取 `Dialogue:` 行第 10 字段起，SRT/VTT 去序号与时间轴，
/// 再剥 `{...}` / `<...>` 标签后统计假名 / 汉字 / 拉丁字母。
///
/// 判定规则（阈值与 RSS-Subtitle-Manager 对齐，全部有单测）：
/// - 假名 ≥ 8 → 日语；其中「无假名且汉字 ≥ 2 的行」≥ 3 行、且这些行的汉字量
///   ≥ max(12, 总汉字/5) → 中日双语（`日文行\N中文行` 的典型形态）。
/// - 否则汉字 ≥ 8 → 按简/繁判别字符集计数分简体/繁体。
/// - 否则拉丁字母 ≥ 30 → 英语。
/// - 都不够 → 未知（**不猜**）。
library;

/// 检测结果。粗粒度语言码投影见 [coarseLanguageCode]。
enum SubtitleContentLanguage {
  japanese,
  simplifiedChinese,
  traditionalChinese,

  /// 中日双语（同屏两行，学日语用户的高价值版本，单列一类不并入 zh）。
  bilingualJaZh,
  english,
  unknown,
}

/// 投影到既有 `ja/zh/en/ko` 粗码（`kJimakuLanguageCodes` 同一值域）；
/// unknown → null。双语归 zh（含中文即可被「中文」筛选命中；细分标签由
/// [subtitleContentLanguageNativeLabel] 展示）。
String? coarseLanguageCode(SubtitleContentLanguage language) =>
    switch (language) {
      SubtitleContentLanguage.japanese => 'ja',
      SubtitleContentLanguage.simplifiedChinese ||
      SubtitleContentLanguage.traditionalChinese ||
      SubtitleContentLanguage.bilingualJaZh =>
        'zh',
      SubtitleContentLanguage.english => 'en',
      SubtitleContentLanguage.unknown => null,
    };

/// 母语写法显示名（与 `jimakuLanguageLabel` 同姿态：不随界面语言变，不走 i18n）。
String? subtitleContentLanguageNativeLabel(SubtitleContentLanguage language) =>
    switch (language) {
      SubtitleContentLanguage.japanese => '日本語',
      SubtitleContentLanguage.simplifiedChinese => '简体中文',
      SubtitleContentLanguage.traditionalChinese => '繁體中文',
      SubtitleContentLanguage.bilingualJaZh => '中日双语',
      SubtitleContentLanguage.english => 'English',
      SubtitleContentLanguage.unknown => null,
    };

/// 简体判别集：只在简体文本出现、繁体文本写作另一形的常用字。
const String _kSimplifiedOnlyChars = '们这对时东乐买卖医还见观说话读书写马鸟龙风'
    '电开关门问间众优传体华单卫压发变经给绝统继绿网义习学为点让边远运进军农'
    '动劳办务历层岁带帮广应张当录隐忆态怀恶悬爱战抢护报担拟拥挂币帅师归';

/// 繁体判别集：与 [_kSimplifiedOnlyChars] 一一对应的繁体形。
const String _kTraditionalOnlyChars = '們這對時東樂買賣醫還見觀說話讀書寫馬鳥龍風'
    '電開關門問間眾優傳體華單衛壓發變經給絕統繼綠網義習學為點讓邊遠運進軍農'
    '動勞辦務歷層歲帶幫廣應張當錄隱憶態懷惡懸愛戰搶護報擔擬擁掛幣帥師歸';

final Set<int> _simplifiedOnly = _kSimplifiedOnlyChars.runes.toSet();
final Set<int> _traditionalOnly = _kTraditionalOnlyChars.runes.toSet();

bool _isKana(int rune) =>
    (rune >= 0x3041 && rune <= 0x3096) || // 平假名
    (rune >= 0x30A1 && rune <= 0x30FA); // 片假名（不含长音符/中点等标点）

bool _isHan(int rune) =>
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    rune == 0x3005; // 々

bool _isLatinLetter(int rune) =>
    (rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A);

/// 从字幕全文提取「对白行」列表（纯函数，便于单测）。
///
/// - ASS/SSA：只取 `Dialogue:` 行的第 10 个逗号字段起（Text 字段本身可含逗号），
///   `\N`/`\n` 内联换行拆成多行（双语字幕的典型形态就在这一步现形）。
/// - SRT/VTT：丢纯序号行、时间轴行（含 `-->`）与 `WEBVTT` 头。
/// - 通用：剥 `{...}`（ASS 覆写块）与 `<...>`（HTML 风格标签）。
List<String> extractSubtitleDialogueLines(String text) {
  final List<String> out = <String>[];
  final bool looksAss = text.contains('Dialogue:');
  for (final String rawLine in text.split(RegExp(r'\r?\n'))) {
    String line = rawLine.trim();
    if (line.isEmpty) continue;
    if (looksAss) {
      if (!line.startsWith('Dialogue:')) continue;
      final List<String> parts = line.split(',');
      if (parts.length < 10) continue;
      line = parts.sublist(9).join(',');
    } else {
      if (line.contains('-->')) continue;
      if (RegExp(r'^\d+$').hasMatch(line)) continue;
      if (line == 'WEBVTT' || line.startsWith('NOTE ')) continue;
    }
    for (final String piece in line.split(RegExp(r'\\[Nn]'))) {
      final String cleaned = piece
          .replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .trim();
      if (cleaned.isNotEmpty) out.add(cleaned);
    }
  }
  return out;
}

/// 见 library doc。输入是**解码后的全文**（字节 → 文本用既有
/// `decodeTextBytes`，本模块不管编码）。
SubtitleContentLanguage detectSubtitleContentLanguage(String text) {
  final List<String> lines = extractSubtitleDialogueLines(text);
  int totalKana = 0;
  int totalHan = 0;
  int totalLatin = 0;
  int hanOnlyLines = 0;
  int hanOnlyHan = 0;
  int simplifiedHits = 0;
  int traditionalHits = 0;
  for (final String line in lines) {
    int lineKana = 0;
    int lineHan = 0;
    for (final int rune in line.runes) {
      if (_isKana(rune)) {
        lineKana++;
      } else if (_isHan(rune)) {
        lineHan++;
        if (_simplifiedOnly.contains(rune)) simplifiedHits++;
        if (_traditionalOnly.contains(rune)) traditionalHits++;
      } else if (_isLatinLetter(rune)) {
        totalLatin++;
      }
    }
    totalKana += lineKana;
    totalHan += lineHan;
    if (lineKana == 0 && lineHan >= 2) {
      hanOnlyLines++;
      hanOnlyHan += lineHan;
    }
  }
  if (totalKana >= 8) {
    // 纯日语字幕里也有汉字拟声/汉字词行（「物音」），要求「无假名汉字行」既有
    // 行数又有总量，才判双语——单个拟声行不构成中文轨。
    final int bilingualFloor = totalHan ~/ 5 > 12 ? totalHan ~/ 5 : 12;
    if (hanOnlyLines >= 3 && hanOnlyHan >= bilingualFloor) {
      return SubtitleContentLanguage.bilingualJaZh;
    }
    return SubtitleContentLanguage.japanese;
  }
  if (totalHan >= 8) {
    return traditionalHits > simplifiedHits
        ? SubtitleContentLanguage.traditionalChinese
        : SubtitleContentLanguage.simplifiedChinese;
  }
  if (totalLatin >= 30) return SubtitleContentLanguage.english;
  return SubtitleContentLanguage.unknown;
}
