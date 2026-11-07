import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PR #3020 审查：「空闲多久停止计时」的提示文案曾把「查词」列为续计时的输入，
/// 但空闲门只认 `StudyClock.touch()`（翻页 / 滚动 / 播放采样），查词路径不调它
/// （BUG-2212，`study_clock.dart` 的 touch 契约）。暂停后连续查词超过阈值就不再入账，
/// 文案承诺落不了地。文案只列真喂空闲门的输入；改契约（让查词喂门）要两边一起改。
void main() {
  const String key = 'reading_stats_idle_timeout_hint';

  /// 各语言里「查词」的说法（旧文案逐字取出），一个都不许出现在提示里。
  const Map<String, List<String>> lookupWords = <String, List<String>>{
    'strings.i18n.json': <String>['look', 'word'],
    'strings_ar.i18n.json': <String>['بحث عن كلمة'],
    'strings_de.i18n.json': <String>['Wortsuche'],
    'strings_es.i18n.json': <String>['buscar una palabra'],
    'strings_fr.i18n.json': <String>['chercher un mot'],
    'strings_id.i18n.json': <String>['mencari kata'],
    'strings_it.i18n.json': <String>['cercare una parola'],
    'strings_ja.i18n.json': <String>['辞書'],
    'strings_ko.i18n.json': <String>['단어 검색'],
    'strings_nl.i18n.json': <String>['woord opzoeken'],
    'strings_pt-BR.i18n.json': <String>['pesquisar uma palavra'],
    'strings_ru.i18n.json': <String>['поиска слова'],
    'strings_th.i18n.json': <String>['ค้นหาคำ'],
    'strings_tr.i18n.json': <String>['sözcük arama'],
    'strings_vi.i18n.json': <String>['tra từ'],
    'strings_zh-CN.i18n.json': <String>['查词'],
    'strings_zh-HK.i18n.json': <String>['查詞'],
  };

  test('空闲门契约仍是「查词不喂门」（改契约要连同文案一起改）', () {
    final String clock = File(
      '../packages/fushi_audio/lib/src/audiobook/study_clock.dart',
    ).readAsStringSync();
    expect(clock, contains('查词不经这里。'));
  });

  test('17 份提示文案都不承诺「查词续计时」', () {
    final List<File> files = Directory('lib/i18n')
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.i18n.json'))
        .toList();
    expect(files.length, lookupWords.length);
    for (final File file in files) {
      final String name = file.uri.pathSegments.last;
      final Map<String, dynamic> json =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final String hint = json[key] as String;
      final List<String>? words = lookupWords[name];
      expect(words, isNotNull, reason: '$name 未登记');
      for (final String word in words!) {
        expect(
          hint.toLowerCase().contains(word.toLowerCase()),
          isFalse,
          reason: '$name：「$word」——查词不喂空闲门',
        );
      }
    }
  });
}
