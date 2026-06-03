import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/audio_source_config.dart';
import 'package:hibiki/src/pages/implementations/dictionary_settings_dialog_page.dart';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Widget buildApp(Widget home) {
    return TranslationProvider(
      child: MaterialApp(home: Scaffold(body: home)),
    );
  }

  // 把对话框 push 成真正的 route，这样行尾「关闭」按钮的 Navigator.pop 能正常
  // 出栈并触发 onSave（对话框直接当 MaterialApp.home 时 pop 根 route 会抛）。
  Future<void> openDialog(
    WidgetTester tester,
    AudioSourcesDialog dialog,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () =>
                    showDialog<void>(context: context, builder: (_) => dialog),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  test('isValidRemoteUrl enforces http(s) + a term/reading placeholder', () {
    expect(AudioSourcesDialog.isValidRemoteUrl('https://x.com/{term}'), isTrue);
    expect(
        AudioSourcesDialog.isValidRemoteUrl('http://x.com/{reading}'), isTrue);
    // 无占位符
    expect(AudioSourcesDialog.isValidRemoteUrl('https://x.com/audio'), isFalse);
    // 非 http(s)
    expect(AudioSourcesDialog.isValidRemoteUrl('ftp://x.com/{term}'), isFalse);
    // 无 scheme / authority
    expect(AudioSourcesDialog.isValidRemoteUrl('{term}'), isFalse);
    expect(AudioSourcesDialog.isValidRemoteUrl(''), isFalse);
  });

  testWidgets('fits a compact desktop window with many remote sources', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 240);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: List<AudioSourceConfig>.generate(
            12,
            (int i) => AudioSourceConfig.remoteAudio(
              url: 'https://audio.example.com/$i/{term}/{reading}',
            ),
          ),
          onSave: (_) {},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('rejects an invalid url and clears the error on a valid one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        AudioSourcesDialog(
          sources: const <AudioSourceConfig>[],
          onSave: (_) {},
        ),
      ),
    );

    await tester.enterText(find.byType(TextField), 'not-a-url');
    await tester.pump();
    expect(find.text(t.audio_source_url_invalid), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'https://x.com/{term}/{reading}',
    );
    await tester.pump();
    expect(find.text(t.audio_source_url_invalid), findsNothing);
  });

  testWidgets(
      'renders local audio rows inline with no master switch and exposes '
      'the add-db entry', (WidgetTester tester) async {
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.localAudio(
              label: 'android.db', path: '/a.db', enabled: true),
        ],
        onSave: (_) {},
        onPickLocalDb: () async => null,
      ),
    );

    // 本地库行直接渲染在统一列表里（无需展开任何分组）。
    expect(find.text('android.db'), findsOneWidget);
    // 「添加本地音频数据库」入口始终可见（不再藏在折叠组里）。
    expect(find.text(t.local_audio_add_db), findsOneWidget);
    // 不再有「本地音频」master 组头 / 总开关。
    expect(find.text(t.local_audio), findsNothing);
  });

  testWidgets('adding a remote url inserts it at the top of the saved list',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: 'https://old.example.com/{term}'),
        ],
        onSave: (List<AudioSourceConfig> v) => saved = v,
      ),
    );

    await tester.enterText(
        find.byType(TextField), 'https://new.example.com/{term}');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.length, 2);
    expect(saved!.first.url, 'https://new.example.com/{term}');
  });

  testWidgets('adding a local db inserts it at the top of the saved list',
      (WidgetTester tester) async {
    List<AudioSourceConfig>? saved;
    await openDialog(
      tester,
      AudioSourcesDialog(
        sources: <AudioSourceConfig>[
          AudioSourceConfig.remoteAudio(url: 'https://old.example.com/{term}'),
        ],
        onSave: (List<AudioSourceConfig> v) => saved = v,
        onPickLocalDb: () async => AudioSourceConfig.localAudio(
            label: 'new.db', path: '/new.db', enabled: true),
      ),
    );

    await tester.tap(find.text(t.local_audio_add_db));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.first.kind, AudioSourceKind.localAudio);
    expect(saved!.first.path, '/new.db');
  });
}
