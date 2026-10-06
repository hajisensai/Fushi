import 'dart:async';

import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/anki/anki_video_template_page.dart';
import 'package:fushi/src/anki/anki_video_template_service.dart';
import 'package:fushi_anki/fushi_anki.dart';

const AnkiNoteTypeDefinition _original = AnkiNoteTypeDefinition(
  name: 'Custom',
  fields: <String>['Expression', 'Picture', 'SentenceAudio'],
  templates: <AnkiCardTemplate>[
    AnkiCardTemplate(
      name: 'Card',
      front: '{{Expression}}',
      back: '{{Picture}}',
    ),
  ],
  css: '.card { color: black; }',
);

class _Service implements AnkiVideoTemplateService {
  AnkiNoteTypeDefinition? definition = _original;
  Completer<void>? pending;
  int writes = 0;
  int reads = 0;
  bool fail = false;
  @override
  bool get supportsEditing => true;
  @override
  Future<AnkiNoteTypeDefinition?> read(String name) async {
    reads++;
    return definition;
  }

  @override
  Future<void> apply({
    required AnkiNoteTypeDefinition expected,
    required AnkiVideoTemplateOptions options,
  }) async {
    writes++;
    if (fail) throw StateError('write refused');
    await pending?.future;
    definition = applyAnkiVideoTemplate(expected, options);
  }

  @override
  Future<void> restore({required AnkiNoteTypeDefinition expected}) async {
    writes++;
    definition = _original;
  }
}

Future<void> _open(
  WidgetTester tester,
  _Service service, {
  bool audio = true,
  Map<String, String> extraMappings = const <String, String>{},
  Future<void> Function()? onApplied,
}) async {
  tester.view.physicalSize = const Size(1000, 1300);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: AnkiVideoTemplatePage(
        service: service,
        modelName: 'Custom',
        onApplied: onApplied,
        initialFieldMappings: <String, String>{
          'Expression': '{term}',
          'Picture': '{card-image}',
          if (audio) 'SentenceAudio': '{sentence-audio}',
          ...extraMappings,
        },
        previewBuilder: (_, String html) => Text('Preview ${html.length}'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('multiple audio fields prevent apply', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      _Service(),
      extraMappings: <String, String>{'Expression': '{sentence-audio}'},
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text(t.anki_video_template_audio_required), findsOneWidget);
  });
  testWidgets('repeated audio token in one field prevents apply', (
    WidgetTester tester,
  ) async {
    await _open(
      tester,
      _Service(),
      extraMappings: <String, String>{
        'SentenceAudio': '{sentence-audio}{sentence-audio}',
      },
    );
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });
  testWidgets('restore consequence is visible before any write', (
    WidgetTester tester,
  ) async {
    final _Service service = _Service();
    await _open(tester, service);
    expect(find.text(t.anki_video_template_restore_hint), findsOneWidget);
    expect(service.writes, 0);
  });
  test('preview moves bottom sample out of original picture position', () {
    const AnkiNoteTypeDefinition definition = AnkiNoteTypeDefinition(
      name: 'Custom',
      fields: <String>['Picture'],
      css: '',
      templates: <AnkiCardTemplate>[
        AnkiCardTemplate(
          name: 'Card',
          front: '',
          back:
              '<section id="picture">{{Picture}}</section><footer>End</footer>',
        ),
      ],
    );
    for (final AnkiVideoPlacement placement in AnkiVideoPlacement.values) {
      final AnkiVideoTemplateOptions options = AnkiVideoTemplateOptions(
        field: 'Picture',
        placement: placement,
      );
      final document = html.parse(
        buildAnkiVideoTemplatePreview(
          applyAnkiVideoTemplate(definition, options),
          options,
        ),
      );
      expect(
        document.querySelectorAll('[data-fushi-preview-video]'),
        hasLength(1),
      );
      expect(
        document.querySelector('#picture [data-fushi-preview-video]') != null,
        placement == AnkiVideoPlacement.picture,
      );
      expect(
        document.querySelector(
              '#fushi-video-player [data-fushi-preview-video]',
            ) !=
            null,
        placement == AnkiVideoPlacement.bottom,
      );
      expect(document.querySelectorAll('[data-fushi-preview-source]'), isEmpty);
    }
  });

  test('picture preview falls back to bottom for inert or hidden fields', () {
    for (final String back in <String>[
      '<template>{{Picture}}</template>',
      '<div hidden>{{Picture}}</div>',
      '<div style="display: none">{{Picture}}</div>',
    ]) {
      final AnkiNoteTypeDefinition definition = AnkiNoteTypeDefinition(
        name: 'Custom',
        fields: const <String>['Picture'],
        css: '',
        templates: <AnkiCardTemplate>[
          AnkiCardTemplate(name: 'Card', front: '', back: back),
        ],
      );
      const AnkiVideoTemplateOptions options = AnkiVideoTemplateOptions(
        field: 'Picture',
        placement: AnkiVideoPlacement.picture,
      );
      final document = html.parse(
        buildAnkiVideoTemplatePreview(
          applyAnkiVideoTemplate(definition, options),
          options,
        ),
      );
      expect(
        document.querySelector(
          '#fushi-video-player [data-fushi-preview-video]',
        ),
        isNotNull,
      );
      expect(
        document.querySelectorAll('[data-fushi-preview-video]'),
        hasLength(1),
      );
    }
  });

  testWidgets('empty templates expose no preview or apply action', (
    WidgetTester tester,
  ) async {
    final _Service service = _Service()
      ..definition = const AnkiNoteTypeDefinition(
        name: 'Empty',
        fields: <String>['Picture'],
        templates: <AnkiCardTemplate>[],
        css: '',
      );
    await _open(tester, service);
    expect(find.text(t.anki_video_template_preview), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.text(t.anki_video_template_unsupported), findsOneWidget);
  });
  testWidgets('opening and preview never write; picks mapped image field', (
    WidgetTester tester,
  ) async {
    final _Service service = _Service();
    await _open(tester, service);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .initialValue,
      'Picture',
    );
    await tester.tap(find.text(t.anki_video_template_preview));
    await tester.pumpAndSettle();
    expect(service.writes, 0);
    expect(find.text(t.anki_video_template_preview_hint), findsOneWidget);
    final DropdownButtonFormField<String> dropdown = tester.widget(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(dropdown.initialValue, 'Picture');
  });

  testWidgets(
    'apply is exclusive, refreshes definition and awaits parent refresh',
    (WidgetTester tester) async {
      final _Service service = _Service()..pending = Completer<void>();
      bool refreshed = false;
      await _open(
        tester,
        service,
        onApplied: () async {
          refreshed = true;
        },
      );
      await tester.tap(find.text(t.anki_video_template_apply));
      await tester.pump();
      expect(service.writes, 1);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<AdaptiveSettingsSwitchRow>(
              find.byType(AdaptiveSettingsSwitchRow),
            )
            .onChanged,
        isNull,
      );
      service.pending!.complete();
      await tester.pumpAndSettle();
      expect(refreshed, isTrue);
      expect(service.reads, 2);
      expect(find.text(t.anki_video_template_applied), findsOneWidget);
      await tester.tap(find.text(t.anki_video_template_restore));
      await tester.pumpAndSettle();
      expect(service.writes, 2);
      expect(find.text(t.anki_video_template_restored), findsOneWidget);
    },
  );

  testWidgets('missing audio mapping prevents apply', (
    WidgetTester tester,
  ) async {
    await _open(tester, _Service(), audio: false);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(find.text(t.anki_video_template_audio_required), findsOneWidget);
  });

  testWidgets('failed writes are visible and controls recover', (
    WidgetTester tester,
  ) async {
    final _Service service = _Service()..fail = true;
    await _open(tester, service);
    await tester.tap(find.text(t.anki_video_template_apply));
    await tester.pumpAndSettle();
    expect(find.textContaining('write refused'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });

  testWidgets('unreadable note type exposes no apply button', (
    WidgetTester tester,
  ) async {
    await _open(tester, _Service()..definition = null);
    expect(find.text(t.anki_video_template_unsupported), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });

  test(
    'static preview renders actual patched template with no executable scripts',
    () {
      const AnkiVideoTemplateOptions options = AnkiVideoTemplateOptions(
        field: 'Picture',
      );
      final String html = buildAnkiVideoTemplatePreview(
        applyAnkiVideoTemplate(_original, options),
        options,
      );
      expect(html, contains('Content-Security-Policy'));
      expect(html, contains('▶ Picture'));
      expect(html, isNot(contains('<script')));
    },
  );
}
