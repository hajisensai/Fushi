import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/cast/cast_substitutions_page.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:material_ui/material_ui.dart';

/// 系列用词替换表编辑页：逐条显示校验问题；开关 / 删除立刻整表交给 save，页面换上
/// save 返回的表。

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('shows validation problems and saves toggles / deletes', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final List<List<CastTextSubstitution>> saved =
        <List<CastTextSubstitution>>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: CastSubstitutionsPage(
            seriesTitle: 'Series A',
            initial: const <CastTextSubstitution>[
              CastTextSubstitution(source: 'セーラー服', replacement: '制服'),
              CastTextSubstitution(source: 'セーラー服', replacement: '服'),
            ],
            save: (List<CastTextSubstitution> next) async {
              saved.add(next);
              return next;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('セーラー服  →  制服'), findsOneWidget);
    // 第二条原文重复：标出来、不生效。
    expect(find.text(t.tts_substitutions_problem_duplicate), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('tts-substitution-0-enabled')),
    );
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.first.enabled, isFalse);
    expect(saved.single.length, 2);

    await tester.tap(
      find.byKey(const ValueKey<String>('tts-substitution-1-delete')),
    );
    await tester.pumpAndSettle();
    expect(saved, hasLength(2));
    expect(saved.last.single.source, 'セーラー服');
    expect(find.text(t.tts_substitutions_problem_duplicate), findsNothing);
    expect(
      castSubstitutionsSummary(saved.last),
      t.tts_substitutions_summary(n: 1),
    );
  });

  testWidgets('name readings: pending marker and fill-in from the cast list', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final List<List<CastTextSubstitution>> saved =
        <List<CastTextSubstitution>>[];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: CastSubstitutionsPage(
            seriesTitle: 'MyGO',
            initial: const <CastTextSubstitution>[
              CastTextSubstitution.name(
                written: '祥子',
                reading: 'さきこ',
                character: '豊川祥子',
              ),
            ],
            roster: const <TtsCastCharacter>[
              TtsCastCharacter(name: '豊川祥子', aliases: <String>['祥子']),
            ],
            save: (List<CastTextSubstitution> next) async {
              saved.add(next);
              return next;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('祥子  →  さきこ'), findsOneWidget);
    expect(
      find.text(t.tts_substitutions_name_character(name: '豊川祥子')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('tts-substitutions-import-roster')),
    );
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    // 只补表里还没有的写法；读法留空，待复核。
    expect(saved.single.last.source, '豊川祥子');
    expect(saved.single.last.isPendingName, isTrue);
    expect(find.text('豊川祥子  →  ?'), findsOneWidget);
    expect(find.text(t.tts_substitutions_name_pending), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });
}
