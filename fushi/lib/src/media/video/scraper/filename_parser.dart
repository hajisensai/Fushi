/// 视频海报刮削流水线 ② 文件名/目录名解析层（anitomy 式规则引擎）。
///
/// 输入是一个文件名或目录名（可含扩展名），输出 [ParsedMediaName]：
/// 按序剥离括号块（字幕组/分辨率/校验码/语言标签/来源/年份/集数）、
/// 集数模式、季度模式、电影提示、副标题，剩余部分清理后即主标题。
/// 纯 Dart 标准库实现，不依赖任何 pub 包。
///
/// G10 第二步起本类是**仓内唯一**的视频文件名规则引擎：导入/分组/种子侧的
/// `parseVideoFilename`（video_filename_parser.dart）已改为本类的窄化适配——
/// 此前两套引擎对同一文件名可能解出不同集数（分组显示第 5 集、刮削按第 3 集查）。
/// 原第二套引擎独有的识别规则（无「第」的 `12話/12集` 简写、`EP 3` 空格集数、
/// `第N巻`）已并入本类，勿再另起副本。
library;

import 'package:fushi/src/media/media_extensions.dart';
import 'package:fushi/src/media/video/scraper/scraper_types.dart';

/// 一个被摘出的括号块：内容 + 它前面的括号外文本（用于判断「标题之后」）。
class _Block {
  const _Block(this.content, this.outsideBefore);

  /// 括号内内容（已 trim，不含括号本身）。
  final String content;

  /// 该块之前累计的括号外文本（先前块已替换为空格）。
  final String outsideBefore;
}

/// 括号块扫描结果：块列表 + 去掉全部块后的外部文本。
class _ScanResult {
  const _ScanResult(this.blocks, this.outside);

  final List<_Block> blocks;
  final String outside;
}

/// 解析过程中的可变累积状态（各字段一经写入不再覆盖，first-wins）。
class _ParseState {
  int? episode;
  int? season;
  int? year;
  String? releaseGroup;
  String? resolution;
  String? secondaryTitle;
  bool isMovieHint = false;
}

/// anitomy 式文件名解析器：从发布组命名中恢复标题/集数/季度等结构化信息。
class FilenameParser {
  FilenameParser._();

  // ─────────────────────────── 公开 API ───────────────────────────

  /// 解析单个文件名或目录名（自动剥离常见视频扩展名）。
  static ParsedMediaName parse(String rawName) {
    final String name = _stripExtension(rawName.trim());
    final _ScanResult scan = _extractBlocks(name);
    final _ParseState st = _ParseState();
    // 未识别的括号块：全括号式命名（【组】【标题】【04】）时作为标题候选。
    final List<String> titleBlocks = <String>[];
    for (int i = 0; i < scan.blocks.length; i++) {
      final _Block b = scan.blocks[i];
      // 「标题之后」判定：该块之前的括号外文本含文字，或已有未识别标题候选块。
      final bool titleSeen =
          _hasTitleChars(b.outsideBefore) || titleBlocks.isNotEmpty;
      _classifyBlock(
        content: b.content,
        index: i,
        titleSeen: titleSeen,
        st: st,
        titleBlocks: titleBlocks,
      );
    }
    String title = _parseTitleText(scan.outside, st);
    if (title.isEmpty) {
      // 外部文本为空（全括号命名）：按序取第一个能产出标题的未识别块。
      for (final String tb in titleBlocks) {
        title = _parseTitleText(tb, st);
        if (title.isNotEmpty) break;
      }
    }
    return ParsedMediaName(
      title: title,
      secondaryTitle: st.secondaryTitle,
      episode: st.episode,
      season: st.season,
      year: st.year,
      releaseGroup: st.releaseGroup,
      resolution: st.resolution,
      isMovieHint: st.isMovieHint,
    );
  }

  /// 给一个视频文件完整路径，返回有序解析候选：
  /// 父目录名解析结果优先（目录名通常更干净、一季只需匹配一次），文件名其次。
  ///
  /// - 父目录名明显不是标题（Downloads / 新建文件夹 / 盘符根 / 单字母 /
  ///   纯数字日期）或解析出空标题时跳过；
  /// - 文件名候选在标题为空且连集数都没有时跳过（如纯设备命名）；
  ///   标题为空但有集数的文件名候选仍保留（供上层做集数一致性校验）。
  static List<ParsedMediaName> candidatesForPath(String filePath) {
    final List<String> segments = filePath
        .split(RegExp(r'[\\/]+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) return const <ParsedMediaName>[];
    final List<ParsedMediaName> out = <ParsedMediaName>[];
    if (segments.length >= 2) {
      final String dirName = segments[segments.length - 2];
      if (!_isBadDirectoryName(dirName)) {
        final ParsedMediaName dirParsed = parse(dirName);
        if (dirParsed.title.isNotEmpty) out.add(dirParsed);
      }
    }
    final ParsedMediaName fileParsed = parse(segments.last);
    if (fileParsed.title.isNotEmpty || fileParsed.episode != null) {
      out.add(fileParsed);
    }
    return out;
  }

  // ─────────────────────────── 扩展名 / 括号块扫描 ───────────────────────────

  /// 结尾剥离视频扩展名（大小写不敏感）。扩展名表与导入 / 目录扫描共用
  /// [kVideoExtensions]（G10 第一步）：此前这里另手写一张只有 9 项的小表，
  /// `.rmvb` 等能导入的格式剥不掉、扩展名留在标题里拉低刮削搜索相似度。
  static String _stripExtension(String name) {
    final int dot = name.lastIndexOf('.');
    if (dot <= 0) return name;
    final String ext = name.substring(dot).toLowerCase();
    return kVideoExtensions.contains(ext) ? name.substring(0, dot) : name;
  }

  /// 支持的括号对（半角 + 全角）。
  static const Map<String, String> _bracketPairs = <String, String>{
    '[': ']',
    '(': ')',
    '【': '】',
    '（': '）',
  };

  /// 逐字符扫描：摘出所有括号块，外部文本中块位置以空格占位（保留 token 边界）。
  static _ScanResult _extractBlocks(String name) {
    final StringBuffer outside = StringBuffer();
    final List<_Block> blocks = <_Block>[];
    int i = 0;
    while (i < name.length) {
      final String ch = name[i];
      final String? closer = _bracketPairs[ch];
      if (closer != null) {
        final int end = name.indexOf(closer, i + 1);
        if (end < 0) {
          // 不闭合的括号当普通字符。
          outside.write(ch);
          i++;
          continue;
        }
        final String content = name.substring(i + 1, end).trim();
        if (content.isNotEmpty) {
          blocks.add(_Block(content, outside.toString()));
        }
        outside.write(' ');
        i = end + 1;
      } else {
        outside.write(ch);
        i++;
      }
    }
    return _ScanResult(blocks, outside.toString());
  }

  /// 文本中是否含可作标题的文字（拉丁字母 / 假名 / 汉字）。
  static final RegExp _titleChar = RegExp(
    r'[A-Za-z぀-ヿ㐀-鿿豈-﫿]',
  );

  static bool _hasTitleChars(String text) => _titleChar.hasMatch(text);

  // ─────────────────────────── 括号块分类 ───────────────────────────

  /// 分辨率 token：`1080p` / `720P` / `2160p` / `4K` / `1920x1080` / `1920X1080`。
  static final RegExp _resolutionToken = RegExp(
    r'^(\d{3,4}[pi]|[248]k|\d{3,4}[x×]\d{3,4})$',
    caseSensitive: false,
  );

  /// 校验码：恰为 8 位十六进制（如 `A1B2C3D4`，纯 8 位数字也按校验码丢弃）。
  static final RegExp _checksum = RegExp(r'^[0-9A-Fa-f]{8}$');

  /// 年份：恰为 4 位数 1900–2099。
  static final RegExp _yearBlock = RegExp(r'^(19|20)\d{2}$');

  /// 块内集数：纯 1–3 位数字（如 `[04]`）。
  static final RegExp _plainEpisodeBlock = RegExp(r'^\d{1,3}$');

  /// 块内集数带尾巴：`[13 END]` / `[13完]`。
  static final RegExp _episodeEndBlock = RegExp(
    r'^(\d{1,3})\s*(?:END|Fin|完)$',
    caseSensitive: false,
  );

  /// 块内 `第N话` 式集数：`[第04话]`（`巻` 自导入端引擎并入，OVA/光盘卷号同解）。
  static final RegExp _cnEpisodeBlock = RegExp(r'^第\s*(\d{1,4})\s*[话話集回巻]$');

  /// 中文语言/字幕标签特征（子串命中即视为语言标签块）。
  static const List<String> _cjkLangMarks = <String>[
    '简繁', '简日', '繁日', '简中', '繁中', '简体', '簡体', '简體', //
    '繁体', '繁體', '内封', '內封', '内嵌', '內嵌', '外挂', '外掛', //
    '双语', '雙語', '字幕',
  ];

  /// 组织后缀特征：含这些字的块是「字幕组/汉化组」而非语言标签。
  static const List<String> _groupMarks = <String>[
    '组', '組', '社', '队', '隊', '屋', '会', '會', //
  ];

  /// ASCII 语言标签 token（仅用于括号块分类，不用于外部文本截断）。
  static const Set<String> _langTokens = <String>{
    'cht', 'chs', 'gb', 'big5', 'jpsc', 'jptc', 'sc', 'tc', //
    'jp', 'jpn', 'chi', 'chs&cht', 'gb&big5', //
  };

  /// 编码/音频/位深 token：`x264` / `x265` / `HEVC` / `AAC` / `FLAC` / `10bit` /
  /// `Hi10P` / `Ma10p` / `HDR` 等。
  static final List<RegExp> _codecTokenPatterns = <RegExp>[
    RegExp(r'^[xh]\.?26[45]$', caseSensitive: false),
    RegExp(r'^(hevc|avc|av1|vp9|xvid|divx)$', caseSensitive: false),
    RegExp(
      r'^(aac|flac|opus|ac3|eac3|dts|dtshd|truehd|mp3|ogg|vorbis|pcm)(x\d)?$',
      caseSensitive: false,
    ),
    RegExp(r'^\d{1,2}-?bits?$', caseSensitive: false),
    RegExp(
      r'^(hi10p|ma10p|ma444p?|hdr|hdr10|hlg|sdr|yuv420p10(le)?)$',
      caseSensitive: false,
    ),
    // 容器名出现在括号块里（如 `【GB_MP4】`）也是噪音。
    RegExp(r'^(mkv|mp4|avi|webm|m2ts|wmv|flv|rmvb)$', caseSensitive: false),
    // 版本号 token：`v2` / `v3`。
    RegExp(r'^v\d$', caseSensitive: false),
  ];

  /// 来源 token：`WebRip` / `WEB-DL` / `BDRip` / `BluRay` / `Baha` / `ABEMA` 等。
  static final RegExp _sourceToken = RegExp(
    r'^(web|webrip|web-dl|webdl|bdrip|bdmv|bd|bluray|blu-ray|dvdrip|dvd|'
    r'remux|hdtv|tvrip|abema|baha|b-global|bglobal|bilibili|cr|crunchyroll|'
    r'sentai|at-x|atx|netflix|nf|amzn|funimation|funi|dsnp|itunes)$',
    caseSensitive: false,
  );

  /// 电影提示（中日文子串）。
  static const List<String> _cjkMovieMarks = <String>[
    '剧场版', '劇場版', '映画', '总集篇', '總集篇', '総集編', //
  ];

  /// token 切分：空格 / 下划线 / 点 / 加号 / & / 逗号（**不含** `-`，
  /// 以免拆散 `VCB-Studio` / `WEB-DL` 这类整体 token）。
  static List<String> _tokenize(String content) => content
      .split(RegExp(r'[ _.+&,]+'))
      .where((String t) => t.isNotEmpty)
      .toList();

  /// 单 token 是否为噪音（编码/来源，含 `hevc-10bit` 这类连字符复合 token）。
  static bool _isNoiseToken(String token, {required bool includeLang}) {
    final String t = token.toLowerCase();
    if (includeLang && _langTokens.contains(t)) return true;
    if (_sourceToken.hasMatch(t)) return true;
    for (final RegExp re in _codecTokenPatterns) {
      if (re.hasMatch(t)) return true;
    }
    // 复合 token（`hevc-10bit`）：各段全是噪音才算噪音。
    if (t.contains('-')) {
      final List<String> parts =
          t.split('-').where((String p) => p.isNotEmpty).toList();
      if (parts.length >= 2 &&
          parts.every(
            (String p) =>
                _sourceToken.hasMatch(p) ||
                (includeLang && _langTokens.contains(p)) ||
                _codecTokenPatterns.any((RegExp re) => re.hasMatch(p)),
          )) {
        return true;
      }
    }
    return false;
  }

  static bool _containsAny(String content, List<String> marks) =>
      marks.any(content.contains);

  /// 括号块是否为纯噪音（语言标签 / 来源 / 编码 / 新番播出季 tag）。
  static bool _isNoiseBlock(String content, List<String> tokens) {
    // `【4月新番】` / `【十月新番】` 这类播出季 tag。
    if (content.contains('新番')) return true;
    // 中文语言标签（排除含组织后缀的字幕组名，如 `桜都字幕组`）。
    if (_containsAny(content, _cjkLangMarks) &&
        !_containsAny(content, _groupMarks)) {
      return true;
    }
    // 全部 token 均为编码/来源/语言噪音（如 `[x265_flac]` / `[AAC AVC]`）。
    if (tokens.isNotEmpty &&
        tokens.every((String t) => _isNoiseToken(t, includeLang: true))) {
      return true;
    }
    return false;
  }

  /// 括号块是否为电影提示（`[剧场版]` / `[Movie]` / `[Gekijouban]`）。
  static bool _isMovieBlock(String content, List<String> tokens) {
    if (_containsAny(content, _cjkMovieMarks)) return true;
    return tokens.any((String t) {
      final String lower = t.toLowerCase();
      return lower == 'movie' || lower == 'gekijouban';
    });
  }

  /// 按序分类一个括号块（分辨率→校验码→年份→集数→电影→噪音→发布组→标题候选）。
  static void _classifyBlock({
    required String content,
    required int index,
    required bool titleSeen,
    required _ParseState st,
    required List<String> titleBlocks,
  }) {
    final List<String> tokens = _tokenize(content);
    // ① 含分辨率 token 的块：记录分辨率，其余部分（如 `Ma10p_1080p`）丢弃。
    for (final String t in tokens) {
      if (_resolutionToken.hasMatch(t)) {
        st.resolution ??= t;
        return;
      }
    }
    // ② 校验码：丢弃。
    if (_checksum.hasMatch(content)) return;
    // ③ 年份。
    if (_yearBlock.hasMatch(content)) {
      st.year ??= int.parse(content);
      return;
    }
    // ④ 块内 `第N话`。
    final RegExpMatch? cnEp = _cnEpisodeBlock.firstMatch(content);
    if (cnEp != null) {
      st.episode ??= int.parse(cnEp.group(1)!);
      return;
    }
    // ⑤ 纯数字集数（须位于标题之后，否则按噪音丢弃）。
    if (_plainEpisodeBlock.hasMatch(content)) {
      if (titleSeen) st.episode ??= int.parse(content);
      return;
    }
    final RegExpMatch? epEnd = _episodeEndBlock.firstMatch(content);
    if (epEnd != null) {
      if (titleSeen) st.episode ??= int.parse(epEnd.group(1)!);
      return;
    }
    // ⑥ 电影提示。
    if (_isMovieBlock(content, tokens)) {
      st.isMovieHint = true;
      return;
    }
    // ⑦ 语言/来源/编码等纯噪音。
    if (_isNoiseBlock(content, tokens)) return;
    // ⑧ 第一个括号块且不匹配其它类别 → 发布组。
    if (index == 0) {
      st.releaseGroup ??= content;
      return;
    }
    // ⑨ 其余未识别块：留作全括号命名的标题候选（外部标题非空时即丢弃）。
    titleBlocks.add(content);
  }

  // ─────────────────────────── 括号外文本解析 ───────────────────────────

  /// 分隔符归一：全角空格→空格、下划线→空格；
  /// 点分隔西式命名（无空格且 ≥2 个点，如 `Mushoku.Tensei.S03E04`）把点当空格。
  static String _normalizeSeparators(String s) {
    // 「点分隔命名」（`Title.S01E09.Sub.WEBRip.ja`）的判定必须在 `_`→空格 **之前**
    // 做：下划线是标题内的普通字符（`ドライブ行かない_`），先替换会让串里凭空多出
    // 空格，判定失效、`.` 不再当分隔符，整串 `.WEBRip.Netflix.ja` 留在标题里
    // （BUG-1435）。
    final String base =
        s.replaceAll('　', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final bool dotSeparated =
        !base.contains(' ') && '.'.allMatches(base).length >= 2;
    String out =
        base.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (dotSeparated) {
      out = out.replaceAll('.', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    return out;
  }

  /// `S01E04` / `s1ep4`：同时产出季度与集数。
  static final RegExp _seasonEpisode = RegExp(
    r'(?:^|[\s._-])[Ss](\d{1,2})\s*[Ee][Pp]?\.?(\d{1,3})(?:[vV]\d{1,2})?(?=$|[\s._-])',
  );

  /// `第04话` / `第4集` / `第04話` / `第4回` / `第2巻`。
  static final RegExp _cnEpisode = RegExp(r'第\s*(\d{1,4})\s*[话話集回巻]');

  /// 无「第」前缀的 `12話` / `12话` / `12集` 简写（字幕组常见；自导入端引擎并入）。
  /// 两端都要求分隔边界，避免误伤 `2016年12話数` 这类连写。
  static final RegExp _cnEpisodeSuffix = RegExp(
    r'(?:^|[\s._-])(\d{1,4})\s*[话話集](?=$|[\s._-])',
  );

  /// `E04` / `EP04` / `EP.04` / `EP 04`（须有分隔边界，避免误伤单词内的 e；
  /// `EP` 与数字间可有空格/点——`Ep 3` 形态自导入端引擎并入）。
  static final RegExp _epToken = RegExp(
    r'(?:^|[\s._-])(?:EP[\s._-]?|E\.?)(\d{1,3})(?=$|[\s._-])',
    caseSensitive: false,
  );

  /// `#04`。
  static final RegExp _hashEpisode = RegExp(r'#\s*(\d{1,3})');

  /// ` - 04` 式集数：空格+连字符后跟数字，容忍 `v2` / `END` / `完` 尾巴。
  static final RegExp _dashEpisode = RegExp(
    r'\s[-‐–—]\s*(\d{1,4})(?:[vV]\d{1,2})?(?:\s*(?:END|Fin|完))?(?=\s|$)',
    caseSensitive: false,
  );

  /// 尾部裸集数（前导零 2–3 位如 `04`，或恰 2 位如 `26`；
  /// 3 位无前导零如 `100` 不认，避免误伤 `Mob Psycho 100`）。
  static final RegExp _bareTrailingEpisode =
      RegExp(r'(?:^|\s)(0\d{1,2}|\d{2})\s*$');

  /// `第三季` / `第3季` / `第2期`（中文数字支持到九十九）。
  static final RegExp _cnSeason =
      RegExp(r'第\s*([0-9零一二两三四五六七八九十]{1,3})\s*[季期]');

  /// `2nd Season` / `3rd Season`。
  static final RegExp _ordinalSeason = RegExp(
    r'(\d{1,2})\s*(?:st|nd|rd|th)\s*Season',
    caseSensitive: false,
  );

  /// `Season 3` / `Season.3`。
  static final RegExp _seasonWord = RegExp(
    r'Season[\s._]*(\d{1,2})',
    caseSensitive: false,
  );

  /// 独立 `S3` token（`S01E04` 已在前面消费，此处不会重复命中）。
  static final RegExp _sToken = RegExp(
    r'(?:^|[\s._-])[Ss](\d{1,2})(?=$|[\s._-])',
  );

  /// `Part 2` / `Part.2`。
  static final RegExp _partSeason = RegExp(
    r'(?:^|[\s._-])Part[\s._]*(\d{1,2})(?=$|[\s._-])',
    caseSensitive: false,
  );

  /// 结尾 ASCII 罗马数字季度：只认独立 token 且 ≤ IV（大写），
  /// 避免 `Hunter X Hunter` 这类单字母误伤。
  static final RegExp _asciiRomanTail = RegExp(r'(?:^|[\s._-])(II|III|IV)\s*$');

  /// 结尾 Unicode 罗马数字（Ⅱ..Ⅹ，可直接贴在标题后如 `无职转生Ⅲ`；
  /// 排除 Ⅰ——单独的「一」季无意义且易误伤）。
  static final RegExp _unicodeRomanTail = RegExp(r'([Ⅱ-Ⅹ])\s*$');

  /// 电影提示（括号外）：`剧场版` 等子串直接剥离；`映画` 只认独立 token
  /// （避免误伤《映画大好きポンポさん》这类标题本身含「映画」的作品）。
  static final RegExp _cjkMovieInline = RegExp(r'剧场版|劇場版|总集篇|總集篇|総集編');
  static final RegExp _cjkEigaToken = RegExp(r'(?:^|\s)映画(?=\s|$)');
  static final RegExp _asciiMovieToken = RegExp(
    r'(?:^|[\s._-])(?:the\s+)?movie(?=$|[\s._-])',
    caseSensitive: false,
  );
  static final RegExp _gekijoubanToken = RegExp(
    r'(?:^|[\s._-])gekijouban(?=$|[\s._-])',
    caseSensitive: false,
  );

  /// `～xxx～` / `〜xxx〜` / `~xxx~` 副标题装饰。
  static final RegExp _tildeSecondary = RegExp(r'[～〜~]([^～〜~]+)[～〜~]');

  /// ` - ` 副标题分隔（集数已在此前被剥离，剩下的 dash 段视为副标题）。
  static final RegExp _dashSplit = RegExp(r'\s[-–—]\s+');
  static final RegExp _colonSplit = RegExp(r'[:：]\s+');

  /// 中文数字 → 整数（一~九十九），失败返回 null。
  static int? _parseCnNumeral(String s) {
    const Map<String, int> digits = <String, int>{
      '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, //
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, //
    };
    if (RegExp(r'^\d+$').hasMatch(s)) return int.tryParse(s);
    final int tenIdx = s.indexOf('十');
    if (tenIdx >= 0) {
      final int? tens = tenIdx == 0 ? 1 : digits[s.substring(0, tenIdx)];
      final String rest = s.substring(tenIdx + 1);
      final int? ones = rest.isEmpty ? 0 : digits[rest];
      if (tens == null || ones == null) return null;
      return tens * 10 + ones;
    }
    return digits[s];
  }

  /// 提取首个匹配并用空格占位删除（保留 token 边界）。
  static String _extractFirst(
    String text,
    RegExp re,
    void Function(RegExpMatch m) onMatch,
  ) {
    final RegExpMatch? m = re.firstMatch(text);
    if (m == null) return text;
    onMatch(m);
    return text.replaceRange(m.start, m.end, ' ');
  }

  /// 外部文本尾部噪音 token 截断（点分隔西式命名的 `1080p WEB-DL x265` 尾巴）：
  /// 自首个分辨率/编码/来源 token 起全部截掉；语言标签不参与（歧义太大）。
  static String _cutTrailingNoiseTokens(String text, _ParseState st) {
    final List<String> tokens =
        text.split(' ').where((String t) => t.isNotEmpty).toList();
    int cut = tokens.length;
    for (int i = 0; i < tokens.length; i++) {
      if (_resolutionToken.hasMatch(tokens[i]) ||
          _isNoiseToken(tokens[i], includeLang: false)) {
        cut = i;
        break;
      }
    }
    if (cut == tokens.length) return text;
    for (int i = cut; i < tokens.length; i++) {
      if (_resolutionToken.hasMatch(tokens[i])) st.resolution ??= tokens[i];
    }
    return tokens.sublist(0, cut).join(' ');
  }

  /// 标题两端清理：去多余空白与分隔符（`- _ . ~` 等）。
  static String _cleanupTitle(String s) {
    String out = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    out = out.replaceFirst(RegExp(r'^[\s\-_.·～〜~]+'), '');
    out = out.replaceFirst(RegExp(r'[\s\-_.·～〜~]+$'), '');
    return out.trim();
  }

  /// 是否「明显不是标题」：纯数字/日期/时间，或设备录制命名（VID_/IMG_ 等）。
  static bool _looksLikeNonTitle(String text) {
    final String t = text.trim();
    if (t.isEmpty) return true;
    // 纯数字 + 日期时间分隔符（`2026-07-01 21-03-55` / `20260701`）。
    if (RegExp(r'^[\d\s\-_.:年月日时分秒]+$').hasMatch(t)) return true;
    // 设备/录屏命名前缀 + 数字（`VID_20260701` / `IMG 0231` / `DSC_0001`）。
    if (RegExp(
      r'^(vid|img|mov|dsc|mvi|dji|gopro?|screenrecording|screenrecord|record)'
      r'[\s\-_.]*\d[\d\s\-_.:]*$',
      caseSensitive: false,
    ).hasMatch(t)) {
      return true;
    }
    return false;
  }

  /// 对括号外文本（或标题候选块）按序应用集数/季度/电影/副标题规则，返回主标题。
  static String _parseTitleText(String raw, _ParseState st) {
    String text = _normalizeSeparators(raw);
    if (text.isEmpty) return '';
    // 整个剩余就是 1–3 位数字：视为集数（如 `[组] 04.mkv` 摘掉块后只剩 `04`）。
    if (_plainEpisodeBlock.hasMatch(text)) {
      st.episode ??= int.parse(text);
      return '';
    }
    // 纯日期/设备命名：直接判空标题，不再做集数误抽取。
    if (_looksLikeNonTitle(text)) return '';
    // ① S01E04（一次给出季+集）。`SxxExx` 是 Jellyfin / Plex / Netflix 系命名的
    // 强边界：它**之后**的一切都不属于系列名——要么是该集独有的分集标题，要么是
    // 发布元数据（`.WEBRip.Netflix.ja`）。此前只把 `SxxExx` 本身替换成空格、分集
    // 标题原样留在标题里，同一部番每集解出不同 series，「按文件夹导入」按 series
    // 分组时分不到一组，12 集变成 12 个独立条目（BUG-1435）。故命中即截断；分集
    // 标题不丢，归入 [ParsedMediaName.secondaryTitle]。
    final RegExpMatch? se = _seasonEpisode.firstMatch(text);
    if (se != null) {
      st.season ??= int.parse(se.group(1)!);
      st.episode ??= int.parse(se.group(2)!);
      final String head = text.substring(0, se.start);
      if (_hasTitleChars(head)) {
        final String tail = _cleanupTitle(
          _cutTrailingNoiseTokens(
            _cleanupTitle(text.substring(se.end)),
            st,
          ),
        );
        if (tail.isNotEmpty) st.secondaryTitle ??= tail;
        text = head;
      } else {
        // 集号前置命名（`S01E04 - Title`）：截断会把标题整个丢空，退回原先的
        // 「替换成空格」行为，让后续规则照常处理剩余文本。
        text = text.replaceRange(se.start, se.end, ' ');
      }
    }
    // ② 其余集数模式（first-wins，括号块里解析出的集数优先保留）。
    if (st.episode == null) {
      text = _extractFirst(text, _cnEpisode, (RegExpMatch m) {
        st.episode = int.parse(m.group(1)!);
      });
    }
    if (st.episode == null) {
      text = _extractFirst(text, _cnEpisodeSuffix, (RegExpMatch m) {
        st.episode = int.parse(m.group(1)!);
      });
    }
    if (st.episode == null) {
      text = _extractFirst(text, _epToken, (RegExpMatch m) {
        st.episode = int.parse(m.group(1)!);
      });
    }
    if (st.episode == null) {
      text = _extractFirst(text, _hashEpisode, (RegExpMatch m) {
        st.episode = int.parse(m.group(1)!);
      });
    }
    if (st.episode == null) {
      text = _extractFirst(text, _dashEpisode, (RegExpMatch m) {
        st.episode = int.parse(m.group(1)!);
      });
    }
    // ③ 电影提示。
    if (_cjkMovieInline.hasMatch(text)) {
      st.isMovieHint = true;
      text = text.replaceAll(_cjkMovieInline, ' ');
    }
    text = _extractFirst(text, _cjkEigaToken, (RegExpMatch m) {
      st.isMovieHint = true;
    });
    text = _extractFirst(text, _asciiMovieToken, (RegExpMatch m) {
      st.isMovieHint = true;
    });
    text = _extractFirst(text, _gekijoubanToken, (RegExpMatch m) {
      st.isMovieHint = true;
    });
    // ④ 季度模式（first-wins；顺序：中文 → 2nd Season → Season N → S3 → Part）。
    if (st.season == null) {
      text = _extractFirst(text, _cnSeason, (RegExpMatch m) {
        st.season = _parseCnNumeral(m.group(1)!);
      });
    }
    if (st.season == null) {
      text = _extractFirst(text, _ordinalSeason, (RegExpMatch m) {
        st.season = int.parse(m.group(1)!);
      });
    }
    if (st.season == null) {
      text = _extractFirst(text, _seasonWord, (RegExpMatch m) {
        st.season = int.parse(m.group(1)!);
      });
    }
    if (st.season == null) {
      text = _extractFirst(text, _sToken, (RegExpMatch m) {
        st.season = int.parse(m.group(1)!);
      });
    }
    if (st.season == null) {
      text = _extractFirst(text, _partSeason, (RegExpMatch m) {
        st.season = int.parse(m.group(1)!);
      });
    }
    // ⑤ 尾部噪音 token 截断（`1080p WEB-DL x265` 等）。
    text = _cutTrailingNoiseTokens(text, st);
    // ⑥ 尾部裸集数（`某科学的超电磁炮 第三季 04` 去掉季后剩的 `04`）。
    if (st.episode == null) {
      final RegExpMatch? bare = _bareTrailingEpisode.firstMatch(text);
      if (bare != null && _hasTitleChars(text.substring(0, bare.start))) {
        st.episode = int.parse(bare.group(1)!);
        text = text.replaceRange(bare.start, text.length, ' ');
      }
    }
    // ⑦ `～xxx～` 副标题。
    text = _extractFirst(text, _tildeSecondary, (RegExpMatch m) {
      final String sub = _cleanupTitle(m.group(1)!);
      if (sub.isNotEmpty) st.secondaryTitle ??= sub;
    });
    // ⑧ ` - xxx` 副标题（xxx 非纯数字时才认）。冒号只在其前已经是
    // 罗马数字季度时才视为副标题分隔，避免破坏 `Re: Zero` 一类正文标题。
    RegExpMatch? secondaryDivider = _dashSplit.firstMatch(text);
    if (secondaryDivider == null) {
      final RegExpMatch? colon = _colonSplit.firstMatch(text);
      if (colon != null) {
        final String head = text.substring(0, colon.start).trimRight();
        if (_asciiRomanTail.hasMatch(head) ||
            _unicodeRomanTail.hasMatch(head)) {
          secondaryDivider = colon;
        }
      }
    }
    if (secondaryDivider != null) {
      final String head = text.substring(0, secondaryDivider.start);
      final String tail = _cleanupTitle(text.substring(secondaryDivider.end));
      if (head.trim().isNotEmpty &&
          tail.isNotEmpty &&
          !RegExp(r'^\d+$').hasMatch(tail)) {
        st.secondaryTitle ??= tail;
        text = head;
      }
    }
    // ⑨ 结尾罗马数字季度（副标题剥离后标题末尾才可见，如 `无职转生Ⅲ`）。
    if (st.season == null) {
      text = _extractFirst(text, _unicodeRomanTail, (RegExpMatch m) {
        st.season = m.group(1)!.codeUnitAt(0) - 0x2160 + 1;
      });
    }
    if (st.season == null) {
      text = _extractFirst(text, _asciiRomanTail, (RegExpMatch m) {
        st.season =
            const <String, int>{'II': 2, 'III': 3, 'IV': 4}[m.group(1)!];
      });
    }
    final String title = _cleanupTitle(text);
    if (_looksLikeNonTitle(title)) return '';
    return title;
  }

  // ─────────────────────────── 目录名过滤 ───────────────────────────

  /// 明显不是作品标题的通用目录名（小写比较）。
  static const Set<String> _genericDirNames = <String>{
    'downloads', 'download', 'videos', 'video', 'movies', 'movie', //
    'films', 'film', 'media', 'temp', 'tmp', 'cache', 'desktop', //
    'documents', 'music', 'pictures', 'recordings', 'anime', 'animes', //
    '动漫', '动画', '新番', '番剧', '电影', '影片', '视频', '下载', //
    '桌面', '文档', '新建文件夹', //
  };

  /// 目录名是否明显不是标题：盘符根 / 单字符 / 纯数字日期 / 通用目录名。
  static bool _isBadDirectoryName(String name) {
    final String t = name.trim();
    if (t.length <= 1) return true;
    // Windows 盘符（`D:`）。
    if (RegExp(r'^[A-Za-z]:$').hasMatch(t)) return true;
    if (_looksLikeNonTitle(t)) return true;
    final String lower = t.toLowerCase();
    if (_genericDirNames.contains(lower)) return true;
    // `新建文件夹 (2)` / `New folder (2)` 变体。
    if (lower.startsWith('新建文件夹') || lower.startsWith('new folder')) {
      return true;
    }
    return false;
  }
}
