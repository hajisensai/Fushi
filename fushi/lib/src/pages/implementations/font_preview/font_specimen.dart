import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_font_loader.dart';
import 'package:fushi/src/reader/reader_settings.dart' show ReaderCustomFontCss;
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

/// 字体行右侧的对照样字：一个拉丁字母对 + 日文最能看出字形差异的几个字
/// （「永」永字八法看笔画、平假名看圆转、片假名看硬折、「漢」看繁密汉字）。
const String kJaFontSpecimenGlyphs = 'Ag 永あア漢';

/// 预览面板的日文正文样张。带假名、汉字、长音与句读，能同时看出字重、字距与
/// 标点位置。
const String kJaFontSampleSentence = '吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。';

/// 字体库样张的样例文种（日文 / 简体中文 / 繁体中文 / 西文）。
///
/// 简繁分开：繁体字体（如教育部楷书）没有简体字形，简体样张里的「黄」「张」会
/// 回退到别的字体，反之亦然——只给一种中文样张就看不出字体本来的样子。
enum FontSampleScript { japanese, simplifiedChinese, traditionalChinese, latin }

/// 样张工具栏只分「日文 / 中文 / 西文」三档；简繁是中文档下的二级选择，由工具栏里
/// 的 [FontChineseVariantSwitch] 切换。
extension FontSampleScriptGroup on FontSampleScript {
  bool get isChinese =>
      this == FontSampleScript.simplifiedChinese ||
      this == FontSampleScript.traditionalChinese;
}

/// 样张工具栏里紧贴「中文」一档右侧的简繁开关：紧凑的胶囊二段「简 | 繁」，与
/// 文种三档同一套分段组件（配色、圆角、字体随主题），只是更矮更窄。标签固定用
/// 中文书写，不随界面语言翻译——这是给看中文的人分辨字形用的；悬停提示（也是读屏
/// 朗读的名称）给全称，走 i18n。
///
/// [script] 不是中文时不渲染（返回空盒）。
class FontChineseVariantSwitch extends StatelessWidget {
  const FontChineseVariantSwitch({
    required this.script,
    required this.onChanged,
    super.key,
  });

  final FontSampleScript script;
  final ValueChanged<FontSampleScript> onChanged;

  @override
  Widget build(BuildContext context) {
    if (!script.isChinese) return const SizedBox.shrink();
    return FushiSegmentedButton<FontSampleScript>(
      key: const ValueKey<String>('font-chinese-variant'),
      showSelectedIcon: false,
      style: FushiSegmentedButton.styleFrom(
        visualDensity: const VisualDensity(horizontal: -4, vertical: -2),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      segments: <ButtonSegment<FontSampleScript>>[
        ButtonSegment<FontSampleScript>(
          value: FontSampleScript.simplifiedChinese,
          label: const Text('简'),
          tooltip: t.font_library_script_simplified_chinese,
        ),
        ButtonSegment<FontSampleScript>(
          value: FontSampleScript.traditionalChinese,
          label: const Text('繁'),
          tooltip: t.font_library_script_traditional_chinese,
        ),
      ],
      selected: <FontSampleScript>{script},
      onSelectionChanged: (Set<FontSampleScript> value) {
        if (value.isNotEmpty && value.first != script) onChanged(value.first);
      },
    );
  }
}

/// 该文种的内容语言标签，喂给 `contentFontFamilies` 决定缺字回退到哪套系统字体。
String fontSampleLanguageTag(FontSampleScript script) => switch (script) {
  FontSampleScript.japanese => 'ja',
  FontSampleScript.simplifiedChinese => 'zh-Hans',
  FontSampleScript.traditionalChinese => 'zh-Hant',
  FontSampleScript.latin => 'en',
};

/// 样张卡默认文字：日文取《吾輩は猫である》开头、中文取《千字文》（简 / 繁两版）、
/// 西文取全字母句。
String fontSampleSentence(FontSampleScript script) => switch (script) {
  FontSampleScript.japanese => '吾輩は猫である。名前はまだ無い。',
  FontSampleScript.simplifiedChinese => '天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。',
  FontSampleScript.traditionalChinese => '天地玄黃，宇宙洪荒。日月盈昃，辰宿列張。',
  FontSampleScript.latin => 'The quick brown fox jumps over the lazy dog.',
};

/// 各用途预览（`FontTargetPreview`）里写死的内容文字，按文种各一套。
///
/// 只放「内容」文字；界面文案（按钮、标题）仍走 i18n。
class FontTargetSampleTexts {
  const FontTargetSampleTexts({
    required this.coverGlyph,
    required this.bookTitle,
    required this.bodyText,
    required this.dictionaryReading,
    required this.dictionaryHeadword,
    required this.dictionaryPartOfSpeech,
    required this.dictionaryDefinitions,
    required this.subtitleLine,
    required this.gameSpeaker,
    required this.gameLine,
  });

  /// 界面样张假封面上的单字。
  final String coverGlyph;

  /// 界面样张列表行里的书名。
  final String bookTitle;

  /// 正文样张（日文另有带振假名的 `kJaFontRubySample`，此字段只在非日文时用）。
  final String bodyText;

  final String dictionaryReading;
  final String dictionaryHeadword;
  final String dictionaryPartOfSpeech;
  final String dictionaryDefinitions;
  final String subtitleLine;
  final String gameSpeaker;
  final String gameLine;
}

/// [script] 对应的各用途预览文字。
FontTargetSampleTexts fontTargetSampleTexts(FontSampleScript script) =>
    switch (script) {
      FontSampleScript.japanese => const FontTargetSampleTexts(
        coverGlyph: '猫',
        bookTitle: '吾輩は猫である',
        bodyText: kJaFontSampleSentence,
        dictionaryReading: 'けんとう',
        dictionaryHeadword: '見当',
        dictionaryPartOfSpeech: '名詞',
        dictionaryDefinitions:
            '① 大体の方向や位置。「駅の見当がつかない」\n'
            '② おおよその予想。見込み。「見当違い」',
        subtitleLine: 'こんなふうに字幕が表示されます。',
        gameSpeaker: '【ミカ】',
        gameLine: '「……ねえ、ここで待っていてくれる？すぐ戻るから。」',
      ),
      FontSampleScript.simplifiedChinese => const FontTargetSampleTexts(
        coverGlyph: '骆',
        bookTitle: '骆驼祥子',
        bodyText: '天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。寒来暑往，秋收冬藏。',
        dictionaryReading: 'jiàn dì',
        dictionaryHeadword: '见地',
        dictionaryPartOfSpeech: '名词',
        dictionaryDefinitions:
            '① 见解；对事物的认识。「很有见地」\n'
            '② 观点，立场。',
        subtitleLine: '字幕会像这样显示。',
        gameSpeaker: '【米卡】',
        gameLine: '「……喂，你能在这里等我吗？我马上回来。」',
      ),
      FontSampleScript.traditionalChinese => const FontTargetSampleTexts(
        coverGlyph: '駱',
        bookTitle: '駱駝祥子',
        bodyText: '天地玄黃，宇宙洪荒。日月盈昃，辰宿列張。寒來暑往，秋收冬藏。',
        dictionaryReading: 'jiàn dì',
        dictionaryHeadword: '見地',
        dictionaryPartOfSpeech: '名詞',
        dictionaryDefinitions:
            '① 見解；對事物的認識。「很有見地」\n'
            '② 觀點，立場。',
        subtitleLine: '字幕會像這樣顯示。',
        gameSpeaker: '【米卡】',
        gameLine: '「……喂，你能在這裡等我嗎？我馬上回來。」',
      ),
      FontSampleScript.latin => const FontTargetSampleTexts(
        coverGlyph: 'A',
        bookTitle: 'Alice in Wonderland',
        bodyText:
            'Alice was beginning to get very tired of sitting by her sister '
            'on the bank, and of having nothing to do.',
        dictionaryReading: '/ˈspes.ɪ.mən/',
        dictionaryHeadword: 'specimen',
        dictionaryPartOfSpeech: 'noun',
        dictionaryDefinitions:
            '① An example regarded as typical of its class.\n'
            '② A sample taken for testing.',
        subtitleLine: 'This is how subtitles will look.',
        gameSpeaker: '[Mika]',
        gameLine: '"...Hey, will you wait here for me? I\'ll be right back."',
      ),
    };

/// 字体库条目（系统族名或导入的文件）→ 引擎里可用的族名。
///
/// 系统字体直接用族名；文件字体经 [AppFontLoader] 注册（幂等，与 app 字体链、
/// 视频字幕、游戏浮窗注册的是同一个族名，互不重复加载）。返回 null = 这个条目
/// 用不了（文件丢失 / 解码失败），UI 显示「无法加载」。
Future<String?> resolveCatalogFontFamily({
  required String name,
  required String? path,
}) {
  if (path == null) {
    final String family = ReaderCustomFontCss.normalizedFontFamilyName(name);
    return Future<String?>.value(family.isEmpty ? null : family);
  }
  return AppFontLoader.resolveAndLoad(<Map<String, dynamic>>[
    <String, dynamic>{'name': name, 'path': path, 'enabled': true},
  ]);
}

/// 一个条目的族名解析状态。
enum FontSpecimenState { loading, ready, unavailable }

/// 字体样张行：左边用该字体写出它自己的名字，右边用同一字体写 [glyphs] 对照。
///
/// 与常见阅读器的字体下拉同形——不用点进去，扫一眼就知道这款字体长什么样。
/// [family] 为 null 时按 [state] 显示加载中或「无法加载」，名字退回界面字体。
class FontSpecimenLine extends StatelessWidget {
  const FontSpecimenLine({
    required this.label,
    required this.family,
    this.state = FontSpecimenState.ready,
    this.glyphs = kJaFontSpecimenGlyphs,
    this.unavailableLabel,
    this.labelStyle,
    this.selected = false,
    super.key,
  });

  final String label;
  final String? family;
  final FontSpecimenState state;
  final String glyphs;

  /// [state] 为 [FontSpecimenState.unavailable] 时右侧显示的说明。
  final String? unavailableLabel;

  /// 名字的基础样式；默认 `titleMedium`。
  final TextStyle? labelStyle;

  /// 选中态：名字与样字改用主色。
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? family = state == FontSpecimenState.ready
        ? this.family
        : null;
    final TextStyle base = (labelStyle ?? theme.textTheme.titleMedium)!
        .copyWith(color: selected ? scheme.primary : null);
    final TextStyle nameStyle = family == null
        ? base
        : base.copyWith(fontFamily: family);
    final Widget trailing = switch (state) {
      FontSpecimenState.loading => SizedBox.square(
        dimension: 16,
        child: FushiCircularProgressIndicator(
          strokeWidth: 2,
          color: scheme.onSurfaceVariant,
        ),
      ),
      FontSpecimenState.unavailable => Text(
        unavailableLabel ?? '',
        style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
      ),
      FontSpecimenState.ready => Text(
        glyphs,
        maxLines: 1,
        softWrap: false,
        style: nameStyle.copyWith(
          color: selected ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    };
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: nameStyle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        trailing,
      ],
    );
  }
}
