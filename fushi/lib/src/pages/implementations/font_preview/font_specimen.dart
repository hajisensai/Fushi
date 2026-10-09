import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/app_font_loader.dart';
import 'package:fushi/src/reader/reader_settings.dart' show ReaderCustomFontCss;
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';

/// 字体行右侧的对照样字：一个拉丁字母对 + 日文最能看出字形差异的几个字
/// （「永」永字八法看笔画、平假名看圆转、片假名看硬折、「漢」看繁密汉字）。
const String kJaFontSpecimenGlyphs = 'Ag 永あア漢';

/// 预览面板的日文正文样张。带假名、汉字、长音与句读，能同时看出字重、字距与
/// 标点位置。
const String kJaFontSampleSentence = '吾輩は猫である。名前はまだ無い。どこで生れたかとんと見当がつかぬ。';

/// 字体库样张卡的三种样例文字（日文 / 中文 / 西文）。
enum FontSampleScript { japanese, chinese, latin }

/// 样张卡默认文字：日文取《吾輩は猫である》开头、中文取《千字文》、西文取全字母句。
String fontSampleSentence(FontSampleScript script) => switch (script) {
  FontSampleScript.japanese => '吾輩は猫である。名前はまだ無い。',
  FontSampleScript.chinese => '天地玄黄，宇宙洪荒。日月盈昃，辰宿列张。',
  FontSampleScript.latin => 'The quick brown fox jumps over the lazy dog.',
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
