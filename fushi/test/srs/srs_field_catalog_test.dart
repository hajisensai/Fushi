// 字段说明目录：内置笔记类型的每个字段都有人话名字与说明；用户写的说明优先。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_field_catalog.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_srs/fushi_srs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final AppLocale locale in <AppLocale>[AppLocale.en, AppLocale.zhCn]) {
    test('[${locale.languageTag}] Lapis / Fushi 卡片的每个字段都在目录里，且有名字与说明', () {
      LocaleSettings.setLocale(locale);
      final Set<String> all = <String>{
        ...LapisNoteType.fields,
        ...FushiCardNoteType.fields,
      };
      for (final String name in all) {
        expect(srsKnownField(name), isNotNull, reason: name);
        expect(srsKnownFieldLabel(name), isNotEmpty, reason: name);
        expect(srsKnownFieldDescription(name), isNotEmpty, reason: name);
      }
      // 目录里没有多余（拼错）的字段名。
      expect(kSrsKnownFields.keys.toSet().difference(all), isEmpty);
    });
  }

  test('显示名 / 说明：用户写的说明优先，未知字段原样显示名字', () {
    LocaleSettings.setLocale(AppLocale.zhCn);
    const SrsFieldDef known = SrsFieldDef(
      id: 'a',
      name: 'ExpressionReading',
      ord: 0,
    );
    expect(srsFieldDisplayName(known), '读音');
    expect(srsFieldDisplayDescription(known), contains('假名'));
    expect(
      srsFieldDisplayDescription(known.copyWith(description: '我的说明')),
      '我的说明',
    );
    const SrsFieldDef mine = SrsFieldDef(id: 'b', name: '我的笔记', ord: 1);
    expect(srsFieldDisplayName(mine), '我的笔记');
    expect(srsFieldDisplayDescription(mine), '');
    expect(
      srsFieldKind(const SrsFieldDef(id: 'c', name: 'Word Audio', ord: 2)),
      SrsFieldKind.audio,
    );
    expect(srsFieldKind(known), SrsFieldKind.text);
    expect(
      srsFieldKind(const SrsFieldDef(id: 'd', name: 'IsClickCard', ord: 3)),
      SrsFieldKind.flag,
    );
  });

  test('字段说明随字段定义持久化：toValue / fromValue 往返，空说明不写键', () {
    const SrsFieldDef f = SrsFieldDef(id: 'x', name: 'N', ord: 0, ankiNum: 7);
    expect(f.toValue().containsKey('description'), isFalse);
    final SrsFieldDef d = f.copyWith(description: '说明');
    final SrsFieldDef back = SrsFieldDef.fromValue('x', d.toValue());
    expect(back.description, '说明');
    expect(back.ankiNum, 7);
    expect(back.copyWith(name: 'M').description, '说明', reason: '改名不丢说明');
  });
}
