/// 新手引导查词教程用的练习句子：按语言给一句日常短句，用户直接拿它去点词查词，
/// 不必自己想「词典里有的词」。
///
/// 纯数据 + 纯函数，与 UI 解耦（模式同 `onboarding_steps.dart`）。
library;

/// 各语言的练习句子，键为 BCP-47 主语言子标签（`zh-Hant` → `zh`）。
///
/// 句子刻意只用最常见的日常词（天气 / 散步），任何入门词典都收录。
const Map<String, String> kOnboardingSampleSentences = <String, String>{
  'ja': '今日はいい天気ですね。散歩に行きましょう。',
  'en': 'The weather is nice today. Let\'s go for a walk.',
  'zh': '今天天气真好，我们出去散步吧。',
  'ko': '오늘 날씨가 정말 좋네요. 산책하러 갈까요?',
  'de': 'Das Wetter ist heute schön. Gehen wir spazieren.',
  'fr': 'Il fait beau aujourd\'hui. Allons nous promener.',
  'es': 'Hoy hace buen tiempo. Vamos a dar un paseo.',
  'it': 'Oggi il tempo è bello. Andiamo a fare una passeggiata.',
  'pt': 'Hoje o tempo está bom. Vamos dar um passeio.',
  'ru': 'Сегодня хорошая погода. Пойдём прогуляемся.',
  'nl': 'Het weer is vandaag mooi. Laten we gaan wandelen.',
  'id': 'Cuacanya bagus hari ini. Ayo jalan-jalan.',
  'th': 'วันนี้อากาศดี ไปเดินเล่นกันเถอะ',
  'tr': 'Bugün hava çok güzel. Hadi yürüyüşe çıkalım.',
  'vi': 'Hôm nay trời đẹp quá. Chúng ta đi dạo nhé.',
  'ar': 'الطقس جميل اليوم. لنذهب في نزهة.',
  'pl': 'Dzisiaj jest ładna pogoda. Chodźmy na spacer.',
  'sv': 'Vädret är fint idag. Låt oss ta en promenad.',
  'el': 'Ο καιρός είναι ωραίος σήμερα. Ας πάμε μια βόλτα.',
  'hi': 'आज मौसम अच्छा है। चलो टहलने चलते हैं।',
  'fi': 'Sää on tänään kaunis. Mennään kävelylle.',
  'la': 'Hodie caelum serenum est. Ambulemus.',
};

/// BCP-47 标签的主语言子标签（`zh-Hant` → `zh`，`ja` → `ja`）；空/null → null。
String? onboardingPrimaryLanguageSubtag(String? tag) {
  if (tag == null) return null;
  final String trimmed = tag.trim().toLowerCase();
  if (trimmed.isEmpty) return null;
  final int dash = trimmed.indexOf('-');
  return dash < 0 ? trimmed : trimmed.substring(0, dash);
}

/// 选出练习句子用哪种语言。
///
/// 依次取：已安装词典里**第一个**有练习句子的词头语言（列表顺序 = 用户词典排序）；
/// 没有可用词典语言时，勾了推荐包（日语词典）就用日语；否则用英语——查词流水线本身
/// 语言无关，句子只是给用户一个能点的东西，猜错语言也只是「查不到」，不会出错。
String onboardingSampleLanguage({
  required Iterable<String?> dictionarySourceLanguages,
  required bool recommendedPackSelected,
}) {
  for (final String? raw in dictionarySourceLanguages) {
    final String? primary = onboardingPrimaryLanguageSubtag(raw);
    if (primary != null && kOnboardingSampleSentences.containsKey(primary)) {
      return primary;
    }
  }
  return recommendedPackSelected ? 'ja' : 'en';
}

/// [onboardingSampleLanguage] 对应的句子。
String onboardingSampleSentence({
  required Iterable<String?> dictionarySourceLanguages,
  required bool recommendedPackSelected,
}) {
  final String language = onboardingSampleLanguage(
    dictionarySourceLanguages: dictionarySourceLanguages,
    recommendedPackSelected: recommendedPackSelected,
  );
  return kOnboardingSampleSentences[language]!;
}
