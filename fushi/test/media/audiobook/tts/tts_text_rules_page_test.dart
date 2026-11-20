import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/tts/tts_services.dart';
import 'package:fushi/src/media/audiobook/tts/tts_text_rules_page.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/tts/tts_pronunciation.dart';
import 'package:material_ui/material_ui.dart';

/// 11-20 反馈 #8：设置 › 语音合成 与「制作有声书」页的文本处理规则是同一份数据
/// （`TtsServices.textRules`），一边改了另一边立刻看到，不各存一份再同步。

class _MemoryPrefs implements PrefStore {
  final Map<String, dynamic> values = <String, dynamic>{};

  @override
  dynamic getPref(String key, {dynamic defaultValue}) =>
      values.containsKey(key) ? values[key] : defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  testWidgets('a rule added in the editor shows up in the studio section', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 设置页与制作台都经这个单例取规则存储。
    final TtsTextRulesStore store = TtsServices.of(_MemoryPrefs()).textRules;
    for (final TtsTextRuleKind kind in TtsTextRuleKind.values) {
      await store.save(kind, const <TtsPronunciationRule>[]);
    }

    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: <Widget>[TtsTextRulesSection(store: store)],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 三类各一行，没有规则时显示说明。
    for (final TtsTextRuleKind kind in TtsTextRuleKind.values) {
      expect(
        find.byKey(ValueKey<String>('tts-text-rules-${kind.name}')),
        findsOneWidget,
      );
    }
    expect(find.text(t.tts_text_rules_pre_synthesis_hint), findsOneWidget);

    // 从制作台的入口进编辑页，加一条合成前替换。
    await tester.tap(
      find.byKey(const ValueKey<String>('tts-text-rules-preSynthesis')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TtsTextRulesPage), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('tts-text-rules-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('tts-text-rule-written')),
      '〜',
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('tts-text-rule-spoken')),
      'ー',
    );
    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();

    expect(store.load(TtsTextRuleKind.preSynthesis).single.written, '〜');
    expect(find.text('〜  →  ー'), findsOneWidget);

    // 另一边（设置页）写进同一份存储：已打开的编辑页与制作台分组都跟着刷新。
    await store.save(TtsTextRuleKind.preSynthesis, const <TtsPronunciationRule>[
      TtsPronunciationRule(written: '〜', spoken: 'ー'),
      TtsPronunciationRule(written: '♪', spoken: ''),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('♪  →  ∅'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(
      find.text(
        ttsTextRulesSummary(
          TtsTextRuleKind.preSynthesis,
          store.load(TtsTextRuleKind.preSynthesis),
        ),
      ),
      findsOneWidget,
    );
    expect(
      ttsTextRulesSummary(
        TtsTextRuleKind.preSynthesis,
        store.load(TtsTextRuleKind.preSynthesis),
      ),
      '${t.tts_text_rules_count(n: 2)} · 〜 → ー',
    );

    await store.save(
      TtsTextRuleKind.pronunciation,
      const <TtsPronunciationRule>[
        TtsPronunciationRule(written: '今日', spoken: 'きょう'),
      ],
    );
    await tester.pumpAndSettle();
    expect(
      find.text('${t.tts_text_rules_count(n: 1)} · 今日 → きょう'),
      findsOneWidget,
    );
  });

  testWidgets('pronunciation needs a reading, replacements may be empty', (
    WidgetTester tester,
  ) async {
    Future<TtsPronunciationRule?> submit(TtsTextRuleKind kind) async {
      TtsPronunciationRule? result;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            // 每次换一棵新树：上一轮没关掉的对话框路由不留下来。
            key: ValueKey<TtsTextRuleKind>(kind),
            home: Builder(
              builder: (BuildContext context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showAppDialog<TtsPronunciationRule>(
                      context: context,
                      builder: (_) => TtsTextRuleDialog(kind: kind),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('tts-text-rule-written')),
        'x',
      );
      await tester.pump();
      await tester.tap(find.text(t.dialog_ok));
      await tester.pumpAndSettle();
      return result;
    }

    expect(await submit(TtsTextRuleKind.pronunciation), isNull);
    final TtsPronunciationRule? cleared = await submit(
      TtsTextRuleKind.postRecognition,
    );
    expect(cleared?.written, 'x');
    expect(cleared?.spoken, '');
  });
}
