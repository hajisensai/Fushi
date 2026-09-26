import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 词典下载的落盘文件名只能是纯文件名。
///
/// 下载地址来自第三方远端 index（BUG-2707 起每次更新检查都采用远端声明的新
/// `downloadUrl`），而 `Uri.pathSegments` 返回的是解码后的片段：`..%2F..%2Fx`
/// 会变成 `../../x`，`%2Fabs` 会让 `path.join` 返回绝对路径——都能写到临时目录
/// 以外。
void main() {
  test('普通地址取最后一段', () {
    expect(
      dictionaryDownloadFileName('https://example.com/dl/JMdict_english.zip'),
      'JMdict_english.zip',
    );
    expect(
      dictionaryDownloadFileName('https://example.com/a.zip?x=1#y'),
      'a.zip',
    );
  });

  test('编码进最后一段的路径分隔符不得逃出临时目录', () {
    expect(
      dictionaryDownloadFileName('https://evil.example/..%2F..%2Fevil.zip'),
      'evil.zip',
    );
    expect(
      dictionaryDownloadFileName('https://evil.example/%2Fetc%2Fpasswd'),
      'passwd',
    );
    expect(
      dictionaryDownloadFileName(r'https://evil.example/..%5C..%5Cevil.zip'),
      'evil.zip',
    );
  });

  test('空名 / 点号 / 路径为空一律回落固定名', () {
    expect(
      dictionaryDownloadFileName('https://example.com/'),
      'dictionary.zip',
    );
    expect(dictionaryDownloadFileName('https://example.com'), 'dictionary.zip');
    expect(
      dictionaryDownloadFileName('https://example.com/%2E%2E'),
      'dictionary.zip',
    );
    expect(
      dictionaryDownloadFileName('https://example.com/.'),
      'dictionary.zip',
    );
  });
}
