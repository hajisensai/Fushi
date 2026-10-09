import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_video_template_service.dart';
import 'package:fushi_anki/fushi_anki.dart';

const AnkiNoteTypeDefinition baseline = AnkiNoteTypeDefinition(
  name: 'Kiku',
  fields: ['Picture', 'Other', 'Audio'],
  css: '',
  templates: [
    AnkiCardTemplate(name: 'Card', front: 'front', back: '{{Picture}}'),
  ],
);

class FakeRepository extends BaseAnkiRepository {
  AnkiNoteTypeDefinition definition = baseline;
  AnkiSettings settings = const AnkiSettings(
    selectedNoteTypeId: 1,
    selectedNoteTypeName: 'Kiku',
    availableNoteTypes: [
      AnkiNoteType(id: 1, name: 'Kiku', fields: ['Picture', 'Other', 'Audio']),
    ],
    fieldMappings: {'Picture': '{card-image}', 'Audio': '{sentence-audio}'},
  );
  int writes = 0;
  bool failSettings = false;
  bool ignoreWrite = false;
  bool partialFirstWrite = false;
  bool externalEditOnFailure = false;
  bool rejectRollback = false;
  bool ignoreRollback = false;
  @override
  bool get supportsNoteTypeEditing => true;
  @override
  Future<AnkiSettings> loadSettings() async => settings;
  @override
  Future<AnkiSettings> updateSettings(
    AnkiSettings Function(AnkiSettings) transform,
  ) async {
    if (failSettings) throw StateError('failed');
    return settings = transform(settings);
  }

  @override
  Future<AnkiNoteTypeDefinition?> readNoteTypeDefinition(String name) async =>
      definition;
  @override
  Future<bool> updateNoteTypeTemplates(
    String name,
    List<AnkiCardTemplate> templates,
  ) async {
    writes++;
    if (writes > 1 && rejectRollback) return false;
    if (writes > 1 && ignoreRollback) return true;
    final Map<String, AnkiCardTemplate> updates = <String, AnkiCardTemplate>{
      for (final AnkiCardTemplate card
          in partialFirstWrite && writes == 1 ? templates.take(1) : templates)
        card.name: card,
    };
    if (!ignoreWrite) {
      definition = AnkiNoteTypeDefinition(
        name: name,
        fields: definition.fields,
        css: definition.css,
        templates: <AnkiCardTemplate>[
          for (final AnkiCardTemplate card in definition.templates)
            if (externalEditOnFailure && writes == 1 && card.name == 'Second')
              const AnkiCardTemplate(
                name: 'Second',
                front: 'user front',
                back: 'user back',
              )
            else
              updates[card.name] ?? card,
        ],
      );
    }
    if (partialFirstWrite && writes == 1) throw StateError('partial write');
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late FakeRepository repo;
  late AnkiVideoTemplateService service;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('video-service-');
    repo = FakeRepository();
    service = AnkiVideoTemplateService(
      repo,
      backupDirectoryResolver: () async => directory,
    );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  Future<void> apply([String field = 'Picture']) async => service.apply(
    expected: (await service.read('Kiku'))!,
    options: AnkiVideoTemplateOptions(field: field),
  );
  test('backup failure never writes backend', () async {
    service = AnkiVideoTemplateService(
      repo,
      backupDirectoryResolver: () async => throw FileSystemException('denied'),
    );
    await expectLater(apply(), throwsA(isA<FileSystemException>()));
    expect(repo.writes, 0);
  });
  test('rejects changed template and endpoint', () async {
    final AnkiNoteTypeDefinition expected = (await service.read('Kiku'))!;
    repo.settings = repo.settings.copyWith(ankiConnectPort: 9000);
    await expectLater(
      service.apply(
        expected: expected,
        options: const AnkiVideoTemplateOptions(field: 'Picture'),
      ),
      throwsStateError,
    );
    expect(repo.writes, 0);
  });
  test('repeated apply restores original mapping', () async {
    await apply();
    await apply();
    await service.restore(expected: (await service.read('Kiku'))!);
    expect(repo.settings.fieldMappings['Picture'], '{card-image}');
    expect(repo.definition.toJson(), baseline.toJson());
  });
  test('requires a separate sentence audio mapping', () async {
    repo.settings = repo.settings.copyWith(
      fieldMappings: <String, String>{'Picture': '{card-image}'},
    );
    await expectLater(apply(), throwsStateError);
    expect(repo.writes, 0);
  });
  test('rejects template changes after preview', () async {
    final AnkiNoteTypeDefinition expected = (await service.read('Kiku'))!;
    repo.definition = AnkiNoteTypeDefinition(
      name: baseline.name,
      fields: baseline.fields,
      templates: baseline.templates,
      css: 'external edit',
    );
    await expectLater(
      service.apply(
        expected: expected,
        options: const AnkiVideoTemplateOptions(field: 'Picture'),
      ),
      throwsStateError,
    );
    expect(repo.writes, 0);
  });
  test('does not restore mapping from another endpoint', () async {
    await apply();
    repo.settings = repo.settings.copyWith(ankiConnectHost: 'other-host');
    await expectLater(
      service.restore(expected: (await service.read('Kiku'))!),
      throwsStateError,
    );
    expect(repo.settings.fieldMappings['Picture'], '{card-video}');
  });
  test('switch field restores previous mapping and absent field', () async {
    await apply();
    await apply('Other');
    expect(repo.settings.fieldMappings['Picture'], '{card-image}');
    expect(repo.settings.fieldMappings['Other'], '{card-video}');
    expect(
      readAnkiVideoTemplateOptions(repo.definition)!.previousFields,
      <String>['Picture'],
    );
    await service.restore(expected: (await service.read('Kiku'))!);
    expect(repo.settings.fieldMappings.containsKey('Other'), false);
  });
  test('field history remains deduplicated after switching back', () async {
    await apply();
    await apply('Other');
    await apply();
    await apply();
    expect(
      readAnkiVideoTemplateOptions(repo.definition)!.previousFields,
      <String>['Other'],
    );
    await service.restore(expected: (await service.read('Kiku'))!);
    expect(repo.settings.fieldMappings['Picture'], '{card-image}');
  });
  test(
    're-enable keeps historical media fields but takes a new mapping baseline',
    () async {
      await apply();
      await apply('Other');
      await service.restore(expected: (await service.read('Kiku'))!);
      repo.settings = repo.settings.copyWith(
        fieldMappings: <String, String>{
          ...repo.settings.fieldMappings,
          'Picture': '{book-cover}',
        },
      );
      await apply();
      final AnkiVideoTemplateOptions options = readAnkiVideoTemplateOptions(
        repo.definition,
      )!;
      expect(options.field, 'Picture');
      expect(options.previousFields, <String>['Other']);
      expect(repo.definition.templates.single.back, contains('{{Other}}'));
      expect(repo.definition.templates.single.back, contains('{{Picture}}'));
      await service.restore(expected: (await service.read('Kiku'))!);
      expect(repo.settings.fieldMappings['Picture'], '{book-cover}');
    },
  );
  test('rejects multiple sentence audio consumers', () async {
    repo.settings = repo.settings.copyWith(
      fieldMappings: <String, String>{
        'Picture': '{card-image}',
        'Audio': '{sentence-audio}',
        'Other': '{sentence-audio}',
      },
    );
    await expectLater(apply(), throwsStateError);
    expect(repo.writes, 0);
  });
  test('rejects repeated sentence audio within one field', () async {
    repo.settings = repo.settings.copyWith(
      fieldMappings: <String, String>{
        'Picture': '{card-image}',
        'Audio': '{sentence-audio} text {sentence-audio}',
      },
    );
    await expectLater(apply(), throwsStateError);
    expect(repo.writes, 0);
  });
  for (final bool externalEdit in <bool>[false, true]) {
    test(
      'partial template write rolls back owned cards, external edit=$externalEdit',
      () async {
        repo.definition = AnkiNoteTypeDefinition(
          name: baseline.name,
          fields: baseline.fields,
          css: '',
          templates: <AnkiCardTemplate>[
            ...baseline.templates,
            const AnkiCardTemplate(
              name: 'Second',
              front: 'second front',
              back: 'second back',
            ),
          ],
        );
        repo.partialFirstWrite = true;
        repo.externalEditOnFailure = externalEdit;
        await expectLater(apply(), throwsStateError);
        expect(repo.definition.templates.first.back, '{{Picture}}');
        expect(
          repo.definition.templates.last.back,
          externalEdit ? 'user back' : 'second back',
        );
        expect(repo.settings.fieldMappings['Picture'], '{card-image}');
        expect(repo.writes, 2);
      },
    );
  }
  for (final bool ignore in <bool>[false, true]) {
    test('failed partial rollback is reported, ignore=$ignore', () async {
      repo.partialFirstWrite = true;
      repo.rejectRollback = !ignore;
      repo.ignoreRollback = ignore;
      await expectLater(
        apply(),
        throwsA(
          isA<StateError>().having(
            (StateError error) => error.message,
            'message',
            contains('自动回滚未完成'),
          ),
        ),
      );
      expect(await directory.list().length, 1);
    });
  }
  test('restore preserves user modifications', () async {
    await apply();
    final AnkiCardTemplate card = repo.definition.templates.single;
    repo.definition = AnkiNoteTypeDefinition(
      name: 'Kiku',
      fields: baseline.fields,
      css: 'new css',
      templates: [
        AnkiCardTemplate(
          name: card.name,
          front: 'changed front',
          back: '${card.back}<p>edit</p>',
        ),
      ],
    );
    repo.settings = repo.settings.copyWith(
      fieldMappings: {
        'Picture': '{book-cover}',
        'Audio': '{sentence-audio}',
        'Other': 'custom',
      },
    );
    await service.restore(expected: (await service.read('Kiku'))!);
    expect(repo.definition.templates.single.back, '{{Picture}}<p>edit</p>');
    expect(repo.definition.templates.single.front, 'changed front');
    expect(repo.definition.css, 'new css');
    expect(repo.settings.fieldMappings['Picture'], '{book-cover}');
    expect(repo.settings.fieldMappings['Other'], 'custom');
  });
  test('rejects non-media mapping', () async {
    await expectLater(apply('Audio'), throwsStateError);
    expect(repo.writes, 0);
  });
  test('failed settings write rolls back templates', () async {
    repo.failSettings = true;
    await expectLater(apply(), throwsStateError);
    expect(repo.definition.toJson(), baseline.toJson());
    expect(await directory.list().length, 1);
  });
  test('silent backend write failure is not success', () async {
    repo.ignoreWrite = true;
    await expectLater(apply(), throwsStateError);
    expect(repo.settings.fieldMappings['Picture'], '{card-image}');
  });
}
