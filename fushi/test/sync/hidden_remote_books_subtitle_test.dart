// BUG-3244：「已从本机移除的远端书」入口副标题的条数走 i18n 文案，不再硬拼 `'$n · 说明'`。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => LocaleSettings.setLocale(AppLocale.en));

  test('没有记录只给说明；有记录时条数按语言的文案拼', () {
    LocaleSettings.setLocale(AppLocale.zhCn);
    expect(hiddenRemoteBooksSubtitle(0), t.remote_hidden_books_hint);
    expect(hiddenRemoteBooksSubtitle(3), '已移除 3 本 · 找回在书架上「仅从本机移除」的远端书');

    LocaleSettings.setLocale(AppLocale.en);
    expect(hiddenRemoteBooksSubtitle(3), startsWith('3 removed · '));
    expect(hiddenRemoteBooksSubtitle(0), isNot(contains('0')));
  });
}
