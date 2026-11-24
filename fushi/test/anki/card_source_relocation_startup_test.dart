// 拍板 hSZjfrcejt：存量出处坐标迁移结束时的提示——复习卡片与制卡历史分开报，不合成一个数。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/card_source_relocation_migration.dart';
import 'package:fushi/src/anki/card_source_relocation_startup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  test('nothing to tell when no scope ran or everything already verified', () {
    expect(cardSourceRelocationReportMessage(), isNull);
    expect(
      cardSourceRelocationReportMessage(
        history: const CardSourceRelocationReport(verified: 9),
        cards: const CardSourceRelocationReport(verified: 4),
      ),
      isNull,
    );
  });

  test('review cards and mining history are reported separately', () {
    final String message = cardSourceRelocationReportMessage(
      history: const CardSourceRelocationReport(relocated: 382, notLocated: 3),
      cards: const CardSourceRelocationReport(relocated: 380, notLocated: 5),
    )!;
    expect(message.split('\n'), <String>[
      t.card_source_relocation_report_title,
      t.card_source_relocation_report_cards(fixed: 380, missed: 5),
      t.card_source_relocation_report_history(fixed: 382, missed: 3),
    ]);
    // 不把两边加成 762：同一张卡在两边各算一条。
    expect(message, isNot(contains('762')));
  });

  test('an external-Anki user only hears about the mining history', () {
    final String message = cardSourceRelocationReportMessage(
      history: const CardSourceRelocationReport(relocated: 12),
    )!;
    expect(message, contains('Mining history'));
    expect(message, isNot(contains('Review cards')));
  });
}
