import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/ankimobile_mined_ledger.dart';
import 'package:fushi/src/anki/ankimobile_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:shared_preferences/shared_preferences.dart';

// iOS 上的「已制卡」✓。
//
// AnkiMobile 的 `anki://x-callback-url` 没有任何回读 collection 的通道（手册 URL
// Schemes 一节只有 addnote / infoForAdding / search / sync），所以 `isDuplicate`
// 此前恒 `false`——iOS 用户永远看不到 ✓。唯一能确知「这张卡真进库了」的时刻是
// AnkiMobile 加完卡回跳的 `x-success`（手册：after the note is added），而那条回调
// 此前收到就丢。本文件守账本的口径、淘汰策略、fail-soft，以及仓库两个消费点。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<List<String>> persisted() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(AnkiMobileMinedLedger.prefsKey);
    if (raw == null) return <String>[];
    return (jsonDecode(raw) as List<Object?>).cast<String>();
  }

  group('AnkiMobileMinedLedger', () {
    test('记过的词才算已制卡', () async {
      final ledger = AnkiMobileMinedLedger();
      expect(await ledger.contains('見物'), isFalse);
      await ledger.record('見物');
      expect(await ledger.contains('見物'), isTrue);
      expect(await ledger.contains('見学'), isFalse);
    });

    test('落账与提问同口径：两边都只 trim', () async {
      final ledger = AnkiMobileMinedLedger();
      await ledger.record('  見物 ');
      expect(await ledger.contains('見物'), isTrue);
      expect(await ledger.contains(' 見物  '), isTrue);
      expect(await persisted(), <String>['見物']);
    });

    test('空词条不落账、也永远不算已制卡', () async {
      final ledger = AnkiMobileMinedLedger();
      await ledger.record('');
      await ledger.record('   ');
      expect(await ledger.contains(''), isFalse);
      expect(await ledger.contains('   '), isFalse);
      expect(await persisted(), isEmpty);
    });

    test('落账穿到持久层：换个实例（≈重启 app）仍认得', () async {
      await AnkiMobileMinedLedger().record('見物');
      final fresh = AnkiMobileMinedLedger();
      expect(await fresh.contains('見物'), isTrue);
    });

    test('同一个词重复制卡不会在账本里留两份', () async {
      final ledger = AnkiMobileMinedLedger();
      await ledger.record('見物');
      await ledger.record('見物');
      expect(await persisted(), <String>['見物']);
    });

    test('超出上限淘汰最久没再制过的那条', () async {
      final ledger = AnkiMobileMinedLedger(limit: 3);
      for (final String word in <String>['一', '二', '三']) {
        await ledger.record(word);
      }
      await ledger.record('四');
      expect(await ledger.contains('一'), isFalse);
      expect(await ledger.contains('四'), isTrue);
      expect(await persisted(), <String>['二', '三', '四']);
    });

    test('重制会把词挪到队尾，淘汰的仍是真正最久没碰过的', () async {
      final ledger = AnkiMobileMinedLedger(limit: 3);
      for (final String word in <String>['一', '二', '三']) {
        await ledger.record(word);
      }
      // 「一」最早，但又制了一次——该被淘汰的变成「二」。
      await ledger.record('一');
      await ledger.record('四');
      expect(await ledger.contains('一'), isTrue);
      expect(await ledger.contains('二'), isFalse);
      expect(await persisted(), <String>['三', '一', '四']);
    });

    test('持久层坏了当空账本继续，不抛', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AnkiMobileMinedLedger.prefsKey: '{not a list',
      });
      final ledger = AnkiMobileMinedLedger();
      expect(await ledger.contains('見物'), isFalse);
      await ledger.record('見物');
      expect(await ledger.contains('見物'), isTrue);
    });

    test('持久层里的杂质（非字符串 / 空串）被滤掉，不抛', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AnkiMobileMinedLedger.prefsKey: jsonEncode(<Object?>[
          '見物',
          42,
          '',
          '  ',
          null,
          '見学',
        ]),
      });
      final ledger = AnkiMobileMinedLedger();
      expect(await ledger.contains('見物'), isTrue);
      expect(await ledger.contains('見学'), isTrue);
      expect(ledger.length, 2);
    });

    test('并发提问只读一次持久层', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        AnkiMobileMinedLedger.prefsKey: jsonEncode(<String>['見物']),
      });
      final ledger = AnkiMobileMinedLedger();
      final List<bool> answers = await Future.wait(<Future<bool>>[
        ledger.contains('見物'),
        ledger.contains('見物'),
        ledger.contains('見学'),
      ]);
      expect(answers, <bool>[true, true, false]);
    });
  });

  group('AnkiMobileRepository 消费账本', () {
    AnkiMobileRepository repoWith(
      AnkiMobileMinedLedger ledger, {
      List<Uri>? opened,
      bool openResult = true,
    }) => AnkiMobileRepository(
      minedLedger: ledger,
      openUrl: (Uri uri) async {
        opened?.add(uri);
        return openResult;
      },
    );

    test('isDuplicate 问账本，不再恒 false', () async {
      final ledger = AnkiMobileMinedLedger();
      final repo = repoWith(ledger);
      expect(await repo.isDuplicate('見物', 'けんぶつ'), isFalse);
      await ledger.record('見物');
      expect(await repo.isDuplicate('見物', 'けんぶつ'), isTrue);
    });

    test('reading 不参与匹配（与 AnkiConnect 的 isDuplicate 同口径）', () async {
      final ledger = AnkiMobileMinedLedger();
      await ledger.record('表');
      final repo = repoWith(ledger);
      expect(await repo.isDuplicate('表', 'おもて'), isTrue);
      expect(await repo.isDuplicate('表', 'ひょう'), isTrue);
      expect(await repo.isDuplicate('表', ''), isTrue);
    });

    test('openWordInAnki：账本认得就开 search 端点', () async {
      final ledger = AnkiMobileMinedLedger();
      await ledger.record('見物');
      final opened = <Uri>[];
      final repo = repoWith(ledger, opened: opened);
      expect(
        await repo.openWordInAnki('見物', 'けんぶつ'),
        AnkiOpenWordOutcome.opened,
      );
      expect(opened, hasLength(1));
      expect(
        opened.single.toString(),
        '$ankiMobileSearchCallback?query=${Uri.encodeComponent('"見物"')}',
      );
    });

    test('openWordInAnki：账本不认得就如实回 noMatch，不去开界面', () async {
      final opened = <Uri>[];
      final repo = repoWith(AnkiMobileMinedLedger(), opened: opened);
      expect(
        await repo.openWordInAnki('見物', 'けんぶつ'),
        AnkiOpenWordOutcome.noMatch,
      );
      expect(await repo.openWordInAnki('', ''), AnkiOpenWordOutcome.noMatch);
      expect(opened, isEmpty);
    });

    test('openWordInAnki：AnkiMobile 打不开是 failed，不是 noMatch', () async {
      final ledger = AnkiMobileMinedLedger();
      await ledger.record('見物');
      final repo = repoWith(ledger, openResult: false);
      expect(
        await repo.openWordInAnki('見物', 'けんぶつ'),
        AnkiOpenWordOutcome.failed,
      );
    });
  });

  group('buildAnkiMobileSearchUri', () {
    test('整词按短语搜，空格编成 %20（与本类其余 URL 同一套编码规则）', () {
      expect(
        buildAnkiMobileSearchUri('a b').toString(),
        '$ankiMobileSearchCallback?query=%22a%20b%22',
      );
    });

    test('引号转义，不会把搜索串截断', () {
      expect(
        buildAnkiMobileSearchUri('a"b').toString(),
        '$ankiMobileSearchCallback?query=${Uri.encodeComponent(r'"a\"b"')}',
      );
    });
  });
}
