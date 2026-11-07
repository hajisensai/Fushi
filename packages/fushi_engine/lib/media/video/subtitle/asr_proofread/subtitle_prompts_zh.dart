/// 普通话（[VideoSubtitleLanguage.mandarin]）各 AI 阶段的提示词（spec
/// `2026-11-04-video-subtitle-mandarin`）。
///
/// 每条与同名日语常量一一对应：规则条目、行协议（`<id><TAB>…`、`END`）、占位符
/// （`{title}` / `{glossary}` / `{lines}` / `{clips}` / `{sources}` / `{identity}` /
/// `{miss}` / `{issues}` / `{table}` / `{done}`）与拆分点（`\n{lines}` / `\n{clips}` /
/// `\n{identity}` / `\n矛盾:`）都相同，所以各阶段的解析与缓存逻辑不用改。措辞面向
/// 「影视作品」而不是「日本动画」：中文原创剧集 / 电影 / 国漫与中文配音的动画都适用。
///
/// 日语提示词不在这里，原样留在各阶段文件里（逐字不变）。
library;

// ---------------------------------------------------------------------------
// S3 校对（对应 subtitle_proofreader.dart 的 kSubtitleProofreadRules）
// ---------------------------------------------------------------------------

const String kSubtitleProofreadRulesZh =
    '''你是中文影视字幕的校对者。下面的中文字幕由语音识别(ASR)生成，你只修正识别错误。
输入:
- 作品名、专名表(如有)
- 每行: id、时间、ASR正文(主)、其它ASR候选(如有)、同时段的他语言字幕(日语/英语等，如有)
规则:
1. 输出必须是实际说出的普通话。不要把翻译字幕译回中文来替换正文。翻译只作为判断意思、人名、用语的线索。
2. 修正明显的识别错误(同音字/近音词错误、人名与作品用语的写法、意思不通的词、被截断的词)。人名统一为专名表的写法。
3. 口头禅、语气词(嗯、啊、呃、那个、就是说)、方言、重复、话说一半保留原样。不要润色文风，也不要概括。
4. 没有把握的地方保持主ASR不变。几个候选之间拿不准时，选最符合上下文和翻译的那个。
5. 不要从翻译里补出主ASR没有的台词。但其它ASR候选里有的词可以采用。
6. 明显是把音乐、噪音转成文字的幻听，可以改成空字符串。
7. 标点从简，使用全角中文标点。保持原有的简体或繁体写法，不做简繁转换。
8. 同一人物、同一用语全片使用同一写法(优先用专名表的写法。表里没有的词不要凭猜测改成专有名词)。
只输出需要修改的行，每行一条: <id><TAB><修改后的正文>(例: 12\t小明来了)。不需要修改的行不写。要把某行改成空字符串时只写 <id><TAB>。
按 id 升序书写，最后一行只写 END(一处修改都没有时只写 END)。不要写说明文字、JSON 或代码块。''';

const String kSubtitleProofreadEvidenceRulesZh = '''补充规则(已有字幕):
9. 「同语言字幕」是这个视频原本附带的中文字幕(人工字幕，或图形字幕的 OCR)。只要与听到的台词相符，用词和写法优先采用它。但 OCR 可能把字形相近的字认错，人工字幕可能删掉口头禅和语气词(按规则 3 保留)。与台词明显不同的地方以 ASR 为准。
10. 「他语言字幕」是翻译。按规则 1、5，只作为判断人名、用语、意思的线索。
11. 标为「主(由已有字幕补全)」的行，是 ASR 没识别到、从已有字幕补回来的台词。与前后文不矛盾就保持原样(要改也只写正文，不写这个标记)。''';

/// 校对批次正文里的标签（对应 `buildProofreadBatchBody` 的日语写法）。
abstract final class SubtitleProofreadLabelsZh {
  static const String before = '\n参考(前面的行，无需修改):';
  static const String target = '\n待校对:';
  static const String readOnly = '参考';
  static const String main = '主';
  static const String mainFromEvidence = '主(由已有字幕补全)';
  static const String candidate = '候选';
  static const String after = '\n参考(后面的行，无需修改):';
  static const String sameLanguage = '同语言字幕';
  static const String otherLanguage = '他语言字幕';
  static const String evidenceText = '字幕';
  static const String workTitle = '作品名';
  static const String glossary = '专名表:';
  static const String misrecognition = '误';
}

// ---------------------------------------------------------------------------
// S4 写法统一（对应 subtitle_consistency_pass.dart 的 kSubtitleConsistencyRules）
// ---------------------------------------------------------------------------

const String kSubtitleConsistencyRulesZh =
    '''你是中文影视作品「{title}」字幕的终校者。下面每一行是机器挑出来的: 可能与专名表写法不一致的词，或可能是演唱(歌词)的行。参考前后行，逐行判断。
- 如果指的是表里的人物或用语，统一成表里的正式写法(同音不同字、相差一个字的写法等)。
- 如果指的不是表里的词(普通词语、别的人物、碰巧相同)，保持原样。
- 能判断为演唱中歌词的行，正文不变，在开头加「♪」(已经有就不用动)。台词不加。
- 其它地方不要改。
只输出要修改的行，每行一条: <id><TAB><修改后的行>。不修改的行不写。按 id 升序书写，最后一行只写 END(没有修改时只写 END)。不要写说明文字。

专名表:
{glossary}

{lines}''';

/// 写法统一批次里的标签（对应日语的 `前` / `対象` / `後` / `疑い`）。
abstract final class SubtitleConsistencyLabelsZh {
  static const String before = '前';
  static const String target = '对象';
  static const String after = '后';
  static const String suspect = '疑点';
  static const String lyric = '歌词?';
}

// ---------------------------------------------------------------------------
// S5 短片判定（对应 subtitle_clip_classifier.dart 的 kSubtitleClipPrompt）
// ---------------------------------------------------------------------------

const String kSubtitleClipPromptZh =
    '''下面是影视作品「{title}」的花絮、短片的语音识别文本(含识别错误)。请判断每个视频是什么。
- song: 只有歌曲的视频(无字幕版片头/片尾、MV 等)。几乎没有台词。
- dialogue: 以台词为主(短剧、正片片段、访谈、解说等)。
- mixed: 台词和歌曲混在一起(预告、宣传片、广告等)。
每行一条: <id><TAB>song / dialogue / mixed 之一。所有 id 都要写，最后一行只写 END。不要写说明文字。

{clips}''';

// ---------------------------------------------------------------------------
// S0 专名表（对应 subtitle_glossary_builder.dart）
// ---------------------------------------------------------------------------

/// 专名表行格式。第二栏「读音」在中文里不填（留空）：拼音对校对没有用，也不该让
/// 模型去推断读音。四栏的形状不变，解析与存储照旧。
const String kSubtitleGlossaryLineFormatZh =
    '输出每行一项(不要说明文字、JSON、代码块): '
    '正确写法<TAB>(留空)<TAB>类别(人物一律以「人名」开头)<TAB>常见误写(用「、」分隔，没有就留空)。'
    '最后一行只写 END。例:\n'
    '林晓\t\t人名(主角)\t林小、林笑\n'
    'END';

const String kSubtitleGlossaryPromptZh =
    '''要用语音识别为影视作品「{title}」(含全部季、电影版)制作中文字幕。请列出容易被识别错的专有名词表。
正确写法请用下面的资料(官方数据、百科摘录)确认。资料里没有的项目，只有确实知道作品官方中文写法时才列入。
列入: 主要和次要角色的全名、剧中的称呼(昵称、外号、带称谓的叫法，例: 小林、林姐、老林)、
有名字的物品或宠物、组织、团体、学校、地名、曲名，以及作品特有的用语。
每项写出正确写法、类别、语音识别容易出现的误写(如有)。
{sources}
{identity}
$kSubtitleGlossaryLineFormatZh''';

const String kSubtitleGlossaryIdentityZh =
    '''用于确认作品的资料(不作为写法依据): 下面是实际音频的语音识别摘录(含错误)。
为避免与同名或类似标题的其它作品(原作不同、翻拍、衍生作品等)混淆，请先用资料确认作品与摘录中出现的人物、用语一致，
再列表。正确写法要取自官方数据、百科等资料，而不是摘录。
摘录:
{lines}
''';

/// 身份校验不过时的反馈。中文没有片假名可当「听到的外来名」，只列没听到的人名。
const String kSubtitleGlossaryWrongWorkZh = '''
上次列出的表里的人名几乎都没有在音频里出现(很可能是别的作品的表): {miss}
请根据上面的摘录重新确定是哪部作品，再列出那部作品的表。
''';

const String kSubtitleGlossaryRecheckZh =
    '''作品「{title}」的专名表里有矛盾。请用下面的资料确认官方网站、百科等的正式写法，输出修正后的整张表。
- 同一人物或用语的不同写法合并为一项，正式写法放第一栏，其它写法放进误写栏。
- 不要把语音识别的输出直接当作正式写法。无法确认的项目删掉。不要留下「待确认」之类的注记。
- 当前的表格式为 正式写法<TAB>(空)<TAB>类别<TAB>误写。
{sources}
矛盾:
{issues}
当前的表:
{table}
$kSubtitleGlossaryLineFormatZh''';

const String kSubtitleGlossaryContinueZh =
    '上次的输出因长度上限中途被截断。已输出的项目: {done}\n'
    '不要重复这些，只用同样的格式输出剩下的项目，最后一行写 END。'
    '没有剩下的就只输出 END。';

/// 专名表资料段的标签（对应 `buildSubtitleGlossarySources` 的日语写法）。
abstract final class SubtitleGlossarySourceLabelsZh {
  static const String official = '作品的官方数据(确定信息，可作为确认作品与写法的依据):';
  static const String originalTitle = '- 原名';
  static const String kanjiTitle = '- 汉字标题';
  static const String namedCharacters =
      '- 登场人物(原名。中文配音作品的中文名可能不同，以资料中的中文写法为准):';
  static const String romajiCharacters = '- 登场人物(只有拉丁字母写法。中文写法请用资料确认):';
  static const String references = '参考资料(百科等摘录):';
  static const String none = '(没有官方数据和参考资料。只列入确实知道作品官方写法的项目)';
  static const String conflictBoth = '既是正式写法的项目，又被列为另一项的误写';
}

/// 「这条没核实」的中文注记（矛盾校验；对应日语的 `要確認|未確認|…`）。
final RegExp kSubtitleGlossaryUnverifiedKindZh = RegExp(
  '待确认|未确认|待核实|ASR|(?:写法|读音|正式写法|详情)不明|^不明|[(（]不明[)）]',
);

// ---------------------------------------------------------------------------
// S4s 歌词补齐（对应 subtitle_song_lyrics.dart）
// ---------------------------------------------------------------------------

const String kSubtitleLyricsExtractPromptZh =
    '''下面是搜索到的网页正文。如果这个页面上有指定歌曲的歌词，请把歌词正文一句一行原样抄写出来。
- 只用页面上写着的文字。不要凭记忆补写、修改或翻译。
- 不要写作词、作曲、演唱等署名信息、广告、网站导航、注音括号。
- 重复的部分也按页面原样写。
- 这个页面上没有指定歌曲的歌词时，只写 NONE。
- 最后一行只写 END。''';

const String kSubtitleSongIdentifyPromptZh =
    '''下面是影视作品中一段演唱的语音识别文本(含识别错误)，以及视频原本附带的字幕里的歌词行(可能是翻译或拼音)。请判断这是哪首歌。
- 知道的话写一行: TITLE<TAB>歌名<TAB>演唱者(歌名和演唱者用原语言的正式写法。不知道演唱者就留空)。
- 没有把握时只写 UNKNOWN。不要凭猜测编造歌名。
- 最后一行只写 END。不要写说明文字。''';

const String kSubtitleLyricsAlignPromptZh =
    '''下面是影视作品中一首歌演唱部分的语音识别(错误很多)，以及这首歌的正确歌词。请把每个演唱行实际唱的歌词对应出来。
- 每行一条: <id><TAB><这一行唱的歌词>。歌词要原样使用给出的歌词行(一个演唱行跨两句歌词时用全角空格连接)。
- 与歌词任何部分都对不上的行(台词、别的歌、无法判断)不写。
- 不要编造歌词里没有的词。电视版等省略的部分可以跳过。
- 按 id 升序书写，最后一行只写 END。不要写说明文字。''';

/// 歌词各请求正文里的标签（对应日语的 `曲` / `作品名` / `区間` / …）。
abstract final class SubtitleLyricsLabelsZh {
  static const String song = '歌曲';
  static const String songUnknown = '(歌名不明。语音识别: {lines})';
  static const String url = 'URL';
  static const String pageText = '页面正文:';
  static const String workTitle = '作品名';
  static const String span = '区间';
  static const String recognized = '语音识别:';
  static const String evidence = '已有字幕的歌词行:';
  static const String lyrics = '歌词:';
  static const String sungLines = '演唱行:';

  /// 联网搜索词的后缀。
  static const String searchSuffix = '歌词';
}
