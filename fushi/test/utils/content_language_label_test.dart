// 内容语言显示名（词典管理页语言组标题、详情「内容语言」、悬浮球 OCR 提示共用）：
// 任何 BCP-47 标签都显示成「语言自称 (完整标签)」，只有主语言不认识时才原样显示。
// 起因：服务器把 `ko-KR` 报成词头语言，组标题直接显示成裸的「ko-KR · 1」。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart'
    show contentLanguageLabelOf, kContentLanguageOptions;

void main() {
  test('选择器里的五项原样返回它们的标签', () {
    for (final ({String? tag, String label}) option
        in kContentLanguageOptions) {
      expect(contentLanguageLabelOf(option.tag!), option.label);
    }
  });

  test('带地区的标签：主语言自称 + 完整标签', () {
    expect(contentLanguageLabelOf('ko-KR'), '한국어 (ko-KR)');
    expect(contentLanguageLabelOf('ja-JP'), '日本語 (ja-JP)');
    expect(contentLanguageLabelOf('en-US'), 'English (en-US)');
    expect(contentLanguageLabelOf('pt-BR'), 'Português (pt-BR)');
  });

  test('选择器没列的主语言按界面语言表的自称', () {
    expect(contentLanguageLabelOf('fr'), 'Français (fr)');
    expect(contentLanguageLabelOf('de-AT'), 'Deutsch (de-AT)');
    expect(contentLanguageLabelOf('vi'), 'Tiếng Việt (vi)');
  });

  test('zh：文字子标签决定简体 / 繁體，只有地区时不替用户猜', () {
    expect(contentLanguageLabelOf('zh-Hans-CN'), '简体中文 (zh-Hans-CN)');
    expect(contentLanguageLabelOf('zh-Hant-TW'), '繁體中文 (zh-Hant-TW)');
    expect(contentLanguageLabelOf('zh-TW'), '中文 (zh-TW)');
    expect(contentLanguageLabelOf('zh'), '中文 (zh)');
  });

  test('主语言不认识：原样返回', () {
    expect(contentLanguageLabelOf('tlh-Latn'), 'tlh-Latn');
    expect(contentLanguageLabelOf('xx'), 'xx');
    expect(contentLanguageLabelOf(''), '');
  });
}
