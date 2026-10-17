import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

AnkiNoteTypeDefinition fixture() => const AnkiNoteTypeDefinition(
  name: 'Custom',
  fields: <String>['Picture', 'Extra'],
  css: '.card {color:red}',
  templates: <AnkiCardTemplate>[
    AnkiCardTemplate(
      name: 'First',
      front: 'front {{Extra}}',
      back: 'before\n{{Picture}}\nafter',
    ),
    AnkiCardTemplate(
      name: 'Second',
      front: 'other',
      back:
          '<template data-field="Picture">{{Picture}}</template><script>hydrate()</script>',
    ),
  ],
);

class _Composer with AnkiNoteComposer {
  Map<String, String> render(
    String filename, {
    bool synchronized = true,
    Map<String, String>? mappings,
  }) => renderMediaPayload(
    settings: AnkiSettings(
      fieldMappings:
          mappings ??
          const <String, String>{
            'Picture': '{card-video}',
            'SentenceAudio': '{sentence-audio}',
          },
    ),
    payload: AnkiMiningPayload(expression: 'test'),
    context: AnkiMiningContext(
      sentence: 'test',
      coverPath: filename,
      synchronizedVideo: synchronized,
    ),
    coverRef: coverMediaRef(filename),
    sentenceAudioRef: '[sound:sentence.mp3]',
    processedAudio: '',
    dictionaryMediaTags: const <String, String>{},
    keepEmpty: true,
  ).fields;
}

void main() {
  test(
    'managed capability and composer reject duplicate or absent sentence audio',
    () {
      final AnkiNoteTypeDefinition adapted = applyAnkiVideoTemplate(
        fixture(),
        const AnkiVideoTemplateOptions(field: 'Picture'),
      );
      for (final Map<String, String> mappings in <Map<String, String>>[
        <String, String>{'Picture': '{card-video}'},
        <String, String>{
          'Picture': '{card-video}',
          'Extra': '{sentence-audio}',
          'Third': '{sentence-audio}',
        },
        <String, String>{
          'Picture': '{card-video}',
          'Extra': '{sentence-audio}{sentence-audio}',
        },
        <String, String>{'Picture': '{card-video}{sentence-audio}'},
      ]) {
        expect(
          noteTypeRendersSynchronizedClip(
            definition: adapted,
            fieldMappings: mappings,
          ),
          isFalse,
        );
        for (final String filename in <String>['clip.mp4', 'clip.webm']) {
          expect(
            () => _Composer().render(filename, mappings: mappings),
            throwsStateError,
          );
        }
      }
      expect(
        noteTypeRendersSynchronizedClip(
          definition: adapted,
          fieldMappings: <String, String>{
            'Picture': '{card-video}',
            'Missing': '{sentence-audio}',
          },
        ),
        isFalse,
      );
    },
  );
  test(
    'single sentence audio helper accepts one token surrounded by other content',
    () {
      expect(
        AnkiHandlebarOptions.singleSentenceAudioField(<String, String>{
          'Audio': '<div>{sentence-audio}</div>',
          'Word': '{audio}',
        }),
        'Audio',
      );
      expect(
        AnkiHandlebarOptions.singleSentenceAudioField(<String, String>{}),
        isNull,
      );
    },
  );

  test('changing fields retains earlier media sources in priority order', () {
    final AnkiNoteTypeDefinition first = applyAnkiVideoTemplate(
      fixture(),
      const AnkiVideoTemplateOptions(field: 'Picture'),
    );
    const AnkiVideoTemplateOptions options = AnkiVideoTemplateOptions(
      field: 'Extra',
      previousFields: <String>['Picture'],
    );
    final AnkiNoteTypeDefinition changed = applyAnkiVideoTemplate(
      first,
      options,
    );
    final String back = changed.templates.first.back;
    final int current = back.indexOf(
      '<template id="fushi-video-source" data-fushi-video-source="1">{{Extra}}</template>',
    );
    final int previous = back.indexOf(
      '<template id="fushi-video-source-1" data-fushi-video-source="1">{{Picture}}</template>',
    );
    expect(current, greaterThanOrEqualTo(0));
    expect(previous, greaterThan(current));
    expect(readAnkiVideoTemplateOptions(changed)!.previousFields, <String>[
      'Picture',
    ]);
    expect(removeAnkiVideoTemplate(changed).toJson(), fixture().toJson());
    expect(
      AnkiVideoTemplateOptions.fromJson(<String, dynamic>{
        'field': 'Picture',
        'placement': 'bottom',
        'autoplay': true,
      }).previousFields,
      isEmpty,
    );
  });
  test(
    'history must contain unique existing fields excluding current field',
    () {
      for (final List<String> history in <List<String>>[
        <String>['Picture'],
        <String>['Extra', 'Extra'],
        <String>['Missing'],
      ]) {
        expect(
          () => applyAnkiVideoTemplate(
            fixture(),
            AnkiVideoTemplateOptions(field: 'Picture', previousFields: history),
          ),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'edited managed player can be recovered but cannot be overwritten or used',
    () {
      const AnkiVideoTemplateOptions options = AnkiVideoTemplateOptions(
        field: 'Picture',
      );
      final AnkiNoteTypeDefinition adapted = applyAnkiVideoTemplate(
        fixture(),
        options,
      );
      final Map<String, dynamic> json = adapted.toJson();
      (json['templates'] as List).first['back'] = adapted.templates.first.back
          .replaceFirst('var host=', 'var editedHost=');
      final AnkiNoteTypeDefinition edited = AnkiNoteTypeDefinition.fromJson(
        json,
      );
      expect(readAnkiVideoTemplateOptions(edited), isNull);
      expect(
        readAnkiVideoTemplateRecoveryOptions(edited)!.toJson(),
        options.toJson(),
      );
      expect(() => applyAnkiVideoTemplate(edited, options), throwsStateError);
      expect(removeAnkiVideoTemplate(edited).toJson(), fixture().toJson());
    },
  );
  test('incomplete and unknown markers prevent destructive removal', () {
    for (final String marker in <String>[
      '<!-- fushi-video:v1:broken',
      '<!-- /fushi-video:v1 -->',
      '<!-- fushi-video:v2:unknown -->',
    ]) {
      final Map<String, dynamic> json = fixture().toJson();
      (json['templates'] as List).first['back'] += marker;
      final AnkiNoteTypeDefinition damaged = AnkiNoteTypeDefinition.fromJson(
        json,
      );
      expect(readAnkiVideoTemplateRecoveryOptions(damaged), isNull);
      expect(() => removeAnkiVideoTemplate(damaged), throwsStateError);
    }
  });
  test('recovery rejects conflicting metadata between cards', () {
    final AnkiNoteTypeDefinition first = applyAnkiVideoTemplate(
      fixture(),
      const AnkiVideoTemplateOptions(field: 'Picture'),
    );
    final AnkiNoteTypeDefinition other = applyAnkiVideoTemplate(
      fixture(),
      const AnkiVideoTemplateOptions(field: 'Extra'),
    );
    final Map<String, dynamic> json = first.toJson();
    (json['templates'] as List).first['back'] = other.templates.first.back;
    expect(
      readAnkiVideoTemplateRecoveryOptions(
        AnkiNoteTypeDefinition.fromJson(json),
      ),
      isNull,
    );
  });

  test(
    'managed WebM stores one inert source and no duplicate sentence player',
    () {
      final Map<String, String> fields = _Composer().render('clip.webm');
      expect(
        fields['Picture'],
        '<video class="fushi-video-source" src="clip.webm" hidden preload="none" playsinline></video>',
      );
      expect(fields['SentenceAudio'], isEmpty);
      expect(fields.values.join(), isNot(contains('[sound:')));
      expect(fields.values.join(), isNot(contains('oncanplay')));
    },
  );
  test('managed MP4 preserves a single native sound and marker', () {
    final Map<String, String> fields = _Composer().render('clip.mp4');
    expect(fields['Picture'], '<span data-fushi-native-video="1"></span>');
    expect(
      RegExp(r'\[sound:clip.mp4\]').allMatches(fields.values.join()).length,
      1,
    );
    expect(fields.values.join(), isNot(contains('<video')));
  });
  test(
    'ordinary picture and sentence audio keep their original representation',
    () {
      final Map<String, String> fields = _Composer().render(
        'cover.png',
        synchronized: false,
      );
      expect(fields['Picture'], '<img src="cover.png">');
      expect(fields['SentenceAudio'], '[sound:sentence.mp3]');
    },
  );
  test('install is reversible and idempotent across every card', () {
    final AnkiNoteTypeDefinition original = fixture();
    const AnkiVideoTemplateOptions options = AnkiVideoTemplateOptions(
      field: 'Picture',
    );
    final AnkiNoteTypeDefinition adapted = applyAnkiVideoTemplate(
      original,
      options,
    );
    expect(removeAnkiVideoTemplate(adapted).toJson(), original.toJson());
    expect(applyAnkiVideoTemplate(adapted, options).toJson(), adapted.toJson());
    expect(adapted.templates.first.front, original.templates.first.front);
    expect(adapted.css, original.css);
    expect(readAnkiVideoTemplateOptions(adapted)!.toJson(), options.toJson());
  });
  test('changing field and playback replaces managed settings only', () {
    final AnkiNoteTypeDefinition first = applyAnkiVideoTemplate(
      fixture(),
      const AnkiVideoTemplateOptions(field: 'Picture'),
    );
    const AnkiVideoTemplateOptions options = AnkiVideoTemplateOptions(
      field: 'Extra',
      placement: AnkiVideoPlacement.picture,
      autoplay: false,
    );
    final AnkiNoteTypeDefinition second = applyAnkiVideoTemplate(
      first,
      options,
    );
    expect(readAnkiVideoTemplateOptions(second)!.toJson(), options.toJson());
    expect(removeAnkiVideoTemplate(second).toJson(), fixture().toJson());
    expect(
      AnkiVideoTemplateOptions.fromJson(options.toJson()).toJson(),
      options.toJson(),
    );
  });
  test('capability needs intact installation and exact selected mapping', () {
    final AnkiNoteTypeDefinition adapted = applyAnkiVideoTemplate(
      fixture(),
      const AnkiVideoTemplateOptions(field: 'Picture'),
    );
    expect(
      noteTypeRendersSynchronizedClip(
        definition: adapted,
        fieldMappings: <String, String>{
          'Picture': '{card-video}',
          'Extra': '{sentence-audio}',
        },
      ),
      isTrue,
    );
    expect(
      noteTypeRendersSynchronizedClip(
        definition: adapted,
        fieldMappings: <String, String>{'Extra': '{card-video}'},
      ),
      isFalse,
    );
    expect(
      noteTypeRendersSynchronizedClip(
        definition: fixture(),
        fieldMappings: <String, String>{
          'Picture': '{card-video}',
          'Extra': '{sentence-audio}',
        },
      ),
      isFalse,
    );
    final Map<String, dynamic> json = adapted.toJson();
    (json['templates'] as List).first['back'] = adapted.templates.first.back
        .replaceFirst('var host=', 'var broken=');
    final AnkiNoteTypeDefinition damaged = AnkiNoteTypeDefinition.fromJson(
      json,
    );
    expect(readAnkiVideoTemplateOptions(damaged), isNull);
    expect(
      noteTypeRendersSynchronizedClip(
        definition: damaged,
        fieldMappings: <String, String>{
          'Picture': '{card-video}',
          'Extra': '{sentence-audio}',
        },
      ),
      isFalse,
    );
  });
  test('missing fields and malformed managed markers cannot be installed', () {
    expect(
      () => applyAnkiVideoTemplate(
        fixture(),
        const AnkiVideoTemplateOptions(field: 'Missing'),
      ),
      throwsArgumentError,
    );
    final Map<String, dynamic> json = fixture().toJson();
    (json['templates'] as List).first['back'] += '<!-- fushi-video:v1:broken';
    expect(
      () => applyAnkiVideoTemplate(
        AnkiNoteTypeDefinition.fromJson(json),
        const AnkiVideoTemplateOptions(field: 'Picture'),
      ),
      throwsStateError,
    );
  });
  test('video field participates in media upload detection', () {
    expect(
      AnkiHandlebarOptions.cardImageFieldNames(<String, String>{
        'Extra': '{card-video}',
      }),
      <String>['Extra'],
    );
  });
}
