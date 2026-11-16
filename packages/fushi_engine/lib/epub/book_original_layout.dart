/// 书本自身声明的排版方向与翻页方向（反馈 sYPkmtitOM：「跟随原书」）。
///
/// 只取 OPF 包文档里的**元数据**，不猜正文 CSS：
/// * `<spine page-progression-direction="rtl|ltr">`（EPUB 2/3 通用的翻页方向）；
/// * `primary-writing-mode`（EPUB 3.0 `<meta property>` / Kindle 式
///   `<meta name content>`，值如 `vertical-rl` / `horizontal-lr` / `horizontal-rl`）；
/// * 两项都没写时退到 `dc:language`：只横排书写的语言推横排（反馈 EwmiUOMTS-）。
///
/// 值域与阅读器设置一致：[BookOriginalLayout.writingMode] 只会是 `vertical-rl` /
/// `horizontal-tb`，[BookOriginalLayout.spreadDirection] 只会是 `rtl` / `ltr`；书没
/// 声明（或声明了阅读器不支持的取值，如蒙古文 `vertical-lr`）的那一项为 null，由
/// 阅读器回落全局设置。
library;

class BookOriginalLayout {
  const BookOriginalLayout({this.writingMode, this.spreadDirection});

  /// 书本什么都没声明。
  static const BookOriginalLayout none = BookOriginalLayout();

  /// `vertical-rl` / `horizontal-tb`；null = 书没声明。
  final String? writingMode;

  /// `rtl` / `ltr`（翻页 / 跨页展开的页序）；null = 书没声明。
  final String? spreadDirection;

  bool get isEmpty => writingMode == null && spreadDirection == null;

  /// 从 OPF 元数据推出书本排版。
  ///
  /// * [primaryWritingMode] 明确给出文字方向时以它为准：`vertical-rl` → 竖排、
  ///   `horizontal-*` → 横排；`vertical-lr` 阅读器不支持，视同未声明。
  /// * 只有 [pageProgressionDirection] 时：`ltr` → 横排（竖排 rl 的书不可能从左往右
  ///   翻）；`rtl` → 竖排，除非 [language] 是阿拉伯文 / 希伯来文这类从右往左书写的
  ///   横排文字（它们的 rtl 翻页对应的是横排正文）。
  /// * 翻页方向优先取 [pageProgressionDirection]，没有时由 [primaryWritingMode] 推
  ///   （`vertical-rl` / `horizontal-rl` → rtl，`horizontal-lr` → ltr）。
  /// * 两项方向元数据都没写时由 `dc:language` 推（反馈 EwmiUOMTS-：英文书什么都
  ///   不声明，落回全局竖排后拉丁字母整行侧躺）：[language] 是只横排书写的文字
  ///   （不是中日韩 / 蒙古文这类可竖排的语言）→ 横排，翻页方向按该文字的书写方向
  ///   （阿拉伯 / 希伯来文 rtl，其余 ltr）。可竖排语言、未声明语言或认不出的取值
  ///   不推，照旧回落全局设置。
  static BookOriginalLayout resolve({
    String? pageProgressionDirection,
    String? primaryWritingMode,
    String? language,
  }) {
    final String? ppd = _normalizeDirection(pageProgressionDirection);
    final String pwm = (primaryWritingMode ?? '').trim().toLowerCase();

    String? writingMode;
    if (pwm == 'vertical-rl') {
      writingMode = 'vertical-rl';
    } else if (pwm.startsWith('horizontal')) {
      writingMode = 'horizontal-tb';
    } else if (pwm.isEmpty) {
      if (ppd == 'ltr') {
        writingMode = 'horizontal-tb';
      } else if (ppd == 'rtl') {
        writingMode = _isRtlScriptLanguage(language)
            ? 'horizontal-tb'
            : 'vertical-rl';
      } else if (_isHorizontalOnlyLanguage(language)) {
        writingMode = 'horizontal-tb';
      }
    }

    String? spreadDirection = ppd;
    if (spreadDirection == null) {
      if (pwm == 'vertical-rl' || pwm == 'horizontal-rl') {
        spreadDirection = 'rtl';
      } else if (pwm == 'horizontal-lr') {
        spreadDirection = 'ltr';
      } else if (pwm.isEmpty && _isHorizontalOnlyLanguage(language)) {
        spreadDirection = _isRtlScriptLanguage(language) ? 'rtl' : 'ltr';
      }
    }

    if (writingMode == null && spreadDirection == null) return none;
    return BookOriginalLayout(
      writingMode: writingMode,
      spreadDirection: spreadDirection,
    );
  }

  /// `rtl` / `ltr` 原样（大小写不敏感）；`default`、空值、其它取值一律 null。
  static String? _normalizeDirection(String? raw) {
    final String value = (raw ?? '').trim().toLowerCase();
    return (value == 'rtl' || value == 'ltr') ? value : null;
  }

  /// 从右往左书写的横排文字（BCP 47 主子标签）。
  static const Set<String> _rtlScriptLanguages = <String>{
    'ar',
    'arc',
    'ckb',
    'dv',
    'fa',
    'he',
    'iw',
    'ps',
    'sd',
    'ug',
    'ur',
    'yi',
  };

  static bool _isRtlScriptLanguage(String? language) {
    final String? primary = _primaryLanguageSubtag(language);
    return primary != null && _rtlScriptLanguages.contains(primary);
  }

  /// 可以竖排书写的语言（BCP 47 / ISO 639-2 主子标签）：中日韩各语种、汉文、
  /// 蒙古文，以及用假名书写的阿伊努语 / 琉球语。这些书没声明方向时**不推**，
  /// 竖排还是横排交给全局设置。
  static const Set<String> _verticalCapableLanguages = <String>{
    'ain',
    'cdo',
    'chi',
    'cjy',
    'cmn',
    'cpx',
    'czh',
    'gan',
    'hak',
    'hsn',
    'ja',
    'jpn',
    'ko',
    'kor',
    'lzh',
    'mn',
    'mnp',
    'mon',
    'nan',
    'ryu',
    'wuu',
    'yue',
    'zh',
    'zho',
  };

  /// 不代表具体语言的特殊码：未定 / 多语种 / 无语言内容 / 未编码。
  static const Set<String> _nonLanguageCodes = <String>{
    'mis',
    'mul',
    'und',
    'zxx',
  };

  /// [language] 是否明确是只横排书写的语言：主子标签是合法的 2～3 位字母码、
  /// 不是特殊码、也不在 [_verticalCapableLanguages] 里。`Japanese` 这类写成语言
  /// 名的非标准取值认不出，视同未声明。
  static bool _isHorizontalOnlyLanguage(String? language) {
    final String? primary = _primaryLanguageSubtag(language);
    return primary != null &&
        !_nonLanguageCodes.contains(primary) &&
        !_verticalCapableLanguages.contains(primary);
  }

  /// BCP 47 主子标签（小写）；空值或不是 2～3 位字母时为 null。
  static String? _primaryLanguageSubtag(String? language) {
    final String tag = (language ?? '').trim().toLowerCase();
    if (tag.isEmpty) return null;
    final String primary = tag.split(RegExp('[-_]')).first;
    return RegExp(r'^[a-z]{2,3}$').hasMatch(primary) ? primary : null;
  }

  @override
  bool operator ==(Object other) =>
      other is BookOriginalLayout &&
      other.writingMode == writingMode &&
      other.spreadDirection == spreadDirection;

  @override
  int get hashCode => Object.hash(writingMode, spreadDirection);

  @override
  String toString() =>
      'BookOriginalLayout(writingMode: $writingMode, '
      'spreadDirection: $spreadDirection)';
}
