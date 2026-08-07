import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_hibiki_source.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/cupertino_settings_renderer.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 一等文本/数字项（阶段 A）：共享 SettingsSchemaItem 分发的渲染、写穿、
/// secret 显隐切换、数字解析/夹取与重置行为。值全走闭包，无需 prefs-backed
/// AppModel。
void main() {
  setUp(() => debugSettingsForceExpandAllSections = true);
  tearDown(() => debugSettingsForceExpandAllSections = false);

  // 可变后备存储：getter/setter 闭包读写这里，模拟真实 pref 写穿。
  late String textValue;
  late String secretValue;
  late num intValue;
  late num doubleValue;
  late List<num> intWrites;

  setUp(() {
    textValue = 'initial-text';
    secretValue = 'initial-secret';
    intValue = 50;
    doubleValue = 1.0;
    intWrites = <num>[];
  });

  SettingsDestination fixture() {
    return SettingsDestination(
      id: SettingsDestinationId.lookup,
      title: 'Fixture',
      icon: Icons.settings,
      sections: <SettingsSection>[
        SettingsSection(
          title: 'Fields',
          items: <SettingsItem>[
            SettingsTextItem(
              id: 'text.plain',
              title: 'Server address',
              icon: Icons.dns_outlined,
              placeholder: 'https://example',
              value: (_) => textValue,
              onChanged: (_, String value) => textValue = value,
            ),
            SettingsTextItem(
              id: 'text.secret',
              title: 'API key',
              icon: Icons.key_outlined,
              secret: true,
              resetValue: (_) => '',
              value: (_) => secretValue,
              onChanged: (_, String value) => secretValue = value,
            ),
            SettingsNumberItem(
              id: 'number.int',
              title: 'Delay',
              icon: Icons.timer_outlined,
              integer: true,
              min: 0,
              max: 100,
              suffixText: 'ms',
              resetValue: (_) => 50,
              value: (_) => intValue,
              onChanged: (_, num value) {
                intValue = value;
                intWrites.add(value);
              },
            ),
            SettingsNumberItem(
              id: 'number.double',
              title: 'Scale',
              icon: Icons.format_size,
              value: (_) => doubleValue,
              onChanged: (_, num value) => doubleValue = value,
            ),
          ],
        ),
      ],
    );
  }

  Widget harness({required bool cupertino}) {
    final FushiDatabase db = FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );
    final ThemeNotifier themeNotifier =
        ThemeNotifier(db, () => const TextTheme())
          ..loadFromPrefsSnapshot(<String, String>{
            'design_system':
                PrefCodec.encode(cupertino ? 'cupertino' : 'material'),
            'app_theme_key': PrefCodec.encode('system-theme'),
            'brightness_mode': PrefCodec.encode('system'),
            'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
          });
    final AppModel appModel = _TestAppModel()..themeNotifier = themeNotifier;
    addTearDown(() async {
      themeNotifier.dispose();
      await db.close();
    });
    return ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
      ],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          platform: cupertino ? TargetPlatform.iOS : TargetPlatform.android,
          extensions: <ThemeExtension<dynamic>>[
            FushiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: Consumer(
          builder: (BuildContext context, WidgetRef ref, _) {
            final SettingsContext settingsContext = SettingsContext(
              context: context,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderHibikiSource.instance,
              refresh: () {},
            );
            return cupertino
                ? const CupertinoSettingsRenderer().buildDetailPage(
                    settingsContext: settingsContext,
                    destination: fixture(),
                  )
                : const MaterialSettingsRenderer().buildDetailPage(
                    settingsContext: settingsContext,
                    destination: fixture(),
                  );
          },
        ),
      ),
    );
  }

  Finder rowField(String title) {
    return find.descendant(
      of: find.widgetWithText(AdaptiveSettingsRow, title),
      matching: find.byType(TextFormField),
    );
  }

  testWidgets('material renders both kinds through the shared dispatch',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(cupertino: false));

    expect(rowField('Server address'), findsOneWidget);
    expect(rowField('API key'), findsOneWidget);
    expect(rowField('Delay'), findsOneWidget);
    expect(rowField('Scale'), findsOneWidget);
  });

  testWidgets('cupertino renders both kinds through the shared dispatch',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(cupertino: true));

    expect(rowField('Server address'), findsOneWidget);
    expect(rowField('API key'), findsOneWidget);
    expect(rowField('Delay'), findsOneWidget);
    expect(rowField('Scale'), findsOneWidget);
  });

  testWidgets('text item debounces keystrokes then writes through',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(cupertino: false));

    await tester.enterText(rowField('Server address'), 'http://10.0.0.2');
    // 防抖窗口内不写。
    expect(textValue, 'initial-text');
    await tester.pump(const Duration(milliseconds: 600));
    expect(textValue, 'http://10.0.0.2');
  });

  testWidgets('text item flushes a pending debounced write on dispose',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(cupertino: false));

    await tester.enterText(rowField('Server address'), 'http://10.0.0.9');
    // 仍在防抖窗口内（500ms 未到）——尚未写穿。
    await tester.pump(const Duration(milliseconds: 100));
    expect(textValue, 'initial-text');

    // 关页（dispose）：pending 输入必须同步冲刷落盘，而不是随 timer 一起丢失。
    await tester.pumpWidget(const SizedBox.shrink());
    expect(textValue, 'http://10.0.0.9',
        reason: '防抖窗口内关页不得丢失已键入的值（审查 Finding 2）');
  });

  testWidgets(
      'number item re-syncs the field text to the clamped value '
      'on unfocus', (WidgetTester tester) async {
    await tester.pumpWidget(harness(cupertino: false));

    final Finder delayField = rowField('Delay');
    await tester.enterText(delayField, '250');
    await tester.pump();
    expect(intValue, 100, reason: '越上界写穿时夹到 max');

    EditableText editable() => tester.widget<EditableText>(
          find.descendant(
            of: find.widgetWithText(AdaptiveSettingsRow, 'Delay'),
            matching: find.byType(EditableText),
          ),
        );
    // 编辑中不打扰：文本保持用户键入的原样。
    expect(editable().controller.text, '250');

    // 失焦（编辑结束）：输入框回显真实存储值，静默夹取不再被陈旧文本掩盖。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(editable().controller.text, '100',
        reason: '失焦后必须回显已提交（夹取后）的值（审查 Finding 6）');
  });

  testWidgets('secret item obscures and the eye toggle reveals',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(cupertino: false));

    final Finder secretRow =
        find.widgetWithText(AdaptiveSettingsRow, 'API key');
    EditableText editable() => tester.widget<EditableText>(
          find.descendant(of: secretRow, matching: find.byType(EditableText)),
        );
    expect(editable().obscureText, isTrue);

    await tester.tap(
      find.descendant(
        of: secretRow,
        matching: find.byIcon(Icons.visibility_outlined),
      ),
    );
    await tester.pump();
    expect(editable().obscureText, isFalse);

    await tester.tap(
      find.descendant(
        of: secretRow,
        matching: find.byIcon(Icons.visibility_off_outlined),
      ),
    );
    await tester.pump();
    expect(editable().obscureText, isTrue);
  });

  testWidgets('secret item reset writes resetValue and refills the field',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(cupertino: false));

    final Finder secretRow =
        find.widgetWithText(AdaptiveSettingsRow, 'API key');
    await tester.tap(
      find.descendant(
          of: secretRow, matching: find.byIcon(Icons.undo_outlined)),
    );
    await tester.pumpAndSettle();

    expect(secretValue, '');
    final EditableText editable = tester.widget<EditableText>(
      find.descendant(of: secretRow, matching: find.byType(EditableText)),
    );
    expect(editable.controller.text, '');
  });

  testWidgets('number item clamps to min/max and skips unparsable input',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(cupertino: false));

    final Finder delayField = rowField('Delay');
    await tester.enterText(delayField, '250');
    await tester.pump();
    expect(intValue, 100, reason: '越上界必须夹到 max');

    await tester.enterText(delayField, '-3');
    await tester.pump();
    expect(intValue, 0, reason: '越下界必须夹到 min');

    final List<num> before = List<num>.of(intWrites);
    await tester.enterText(delayField, 'abc');
    await tester.pump();
    expect(intWrites, before, reason: '解析失败不得写穿');

    await tester.enterText(delayField, '42');
    await tester.pump();
    expect(intValue, 42);
  });

  testWidgets('double number item parses decimals', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness(cupertino: false));

    await tester.enterText(rowField('Scale'), '1.75');
    await tester.pump();
    expect(doubleValue, 1.75);
  });

  testWidgets('number item reset writes the reset value',
      (WidgetTester tester) async {
    await tester.pumpWidget(harness(cupertino: false));

    final Finder delayField = rowField('Delay');
    await tester.enterText(delayField, '99');
    await tester.pump();
    expect(intValue, 99);

    final Finder delayRow = find.widgetWithText(AdaptiveSettingsRow, 'Delay');
    await tester.tap(
      find.descendant(of: delayRow, matching: find.byIcon(Icons.undo_outlined)),
    );
    await tester.pumpAndSettle();
    expect(intValue, 50);
  });
}

/// 轻量 AppModel：本测试的行值全走闭包后备存储，不触 prefs/DB。
class _TestAppModel extends AppModel {
  _TestAppModel() : super(testPlatformServices());

  @override
  Locale get appLocale => const Locale('en', 'US');
}
