import 'package:test/test.dart';
import 'package:fushi/src/ocr/screen_ocr_language.dart';

void main() {
  test('默认内容语言为空或只有空白时回落日语', () {
    expect(resolveScreenOcrLanguage(''), kScreenOcrFallbackLanguage);
    expect(resolveScreenOcrLanguage('   '), 'ja');
  });

  test('设了默认内容语言就原样交给系统 OCR（去首尾空白）', () {
    expect(resolveScreenOcrLanguage('zh-Hans'), 'zh-Hans');
    expect(resolveScreenOcrLanguage(' zh-TW '), 'zh-TW');
    expect(resolveScreenOcrLanguage('ko'), 'ko');
  });
}
