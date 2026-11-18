import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
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

mixin FakeBackend on BaseAnkiRepository {
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
}

class FakeRepository extends BaseAnkiRepository with FakeBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 真后端的子类（类名与父类不同）：备份键必须仍是冻结的父类名常量。
class RenamedConnectRepository extends AnkiConnectRepository with FakeBackend {}

class RenamedDroidRepository extends AnkiRepository with FakeBackend {}

Matcher throwsTemplate(AnkiVideoTemplateErrorCode code) => throwsA(
  isA<AnkiVideoTemplateException>().having(
    (AnkiVideoTemplateException error) => error.code,
    'code',
    code,
  ),
);

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
      throwsTemplate(AnkiVideoTemplateErrorCode.targetChanged),
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
    await expectLater(
      apply(),
      throwsTemplate(AnkiVideoTemplateErrorCode.audioMappingRequired),
    );
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
      throwsTemplate(AnkiVideoTemplateErrorCode.templateChanged),
    );
    expect(repo.writes, 0);
  });
  test('does not restore mapping from another endpoint', () async {
    await apply();
    repo.settings = repo.settings.copyWith(ankiConnectHost: 'other-host');
    await expectLater(
      service.restore(expected: (await service.read('Kiku'))!),
      throwsTemplate(AnkiVideoTemplateErrorCode.restoreBackupMissing),
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
    await expectLater(
      apply(),
      throwsTemplate(AnkiVideoTemplateErrorCode.audioMappingRequired),
    );
    expect(repo.writes, 0);
  });
  test('rejects repeated sentence audio within one field', () async {
    repo.settings = repo.settings.copyWith(
      fieldMappings: <String, String>{
        'Picture': '{card-image}',
        'Audio': '{sentence-audio} text {sentence-audio}',
      },
    );
    await expectLater(
      apply(),
      throwsTemplate(AnkiVideoTemplateErrorCode.audioMappingRequired),
    );
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
          isA<AnkiVideoTemplateException>()
              .having(
                (AnkiVideoTemplateException error) => error.code,
                'code',
                AnkiVideoTemplateErrorCode.rollbackIncomplete,
              )
              // 两个内层错误都保留：原始失败（后端写到一半抛的）与回滚失败。
              .having(
                (AnkiVideoTemplateException error) => error.cause,
                'cause',
                isA<StateError>().having(
                  (StateError error) => error.message,
                  'message',
                  'partial write',
                ),
              )
              .having(
                (AnkiVideoTemplateException error) => error.rollbackCause,
                'rollbackCause',
                isA<AnkiVideoTemplateException>().having(
                  (AnkiVideoTemplateException error) => error.code,
                  'code',
                  ignore
                      ? AnkiVideoTemplateErrorCode.rollbackVerificationFailed
                      : AnkiVideoTemplateErrorCode.rollbackRejected,
                ),
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
    // 选的就是句子音频那个字段：先被「句子音频要映射在另一个字段」拦下。
    await expectLater(
      apply('Audio'),
      throwsTemplate(AnkiVideoTemplateErrorCode.audioMappingRequired),
    );
    repo.settings = repo.settings.copyWith(
      fieldMappings: <String, String>{
        ...repo.settings.fieldMappings,
        'Other': '{term}',
      },
    );
    await expectLater(
      apply('Other'),
      throwsTemplate(AnkiVideoTemplateErrorCode.fieldHasOtherContent),
    );
    expect(repo.writes, 0);
  });
  test('failed settings write rolls back templates', () async {
    repo.failSettings = true;
    // 设置写不进去，回滚里的设置写同样失败：模板回滚了，报「回滚未完成」并带两个内层错误。
    await expectLater(
      apply(),
      throwsTemplate(AnkiVideoTemplateErrorCode.rollbackIncomplete),
    );
    expect(repo.definition.toJson(), baseline.toJson());
    expect(await directory.list().length, 1);
  });
  test('silent backend write failure is not success', () async {
    repo.ignoreWrite = true;
    await expectLater(
      apply(),
      throwsTemplate(AnkiVideoTemplateErrorCode.writeVerificationFailed),
    );
    expect(repo.settings.fieldMappings['Picture'], '{card-image}');
  });

  group('BUG-4826 坏备份不挡住有效备份', () {
    /// 与服务写备份同一套命名：`sha256(target)-<微秒>.json`，取现有备份的前缀。
    Future<String> keyPrefix() async {
      final File existing = (await directory.list().toList())
          .whereType<File>()
          .first;
      return existing.uri.pathSegments.last.split('-').first;
    }

    // 比任何真实备份都新（文件名倒序排在最前）的几种坏文件：写到一半的 JSON、空文件、
    // 合法 JSON 但不是备份、缺字段的备份。
    const Map<String, String> corrupt = <String, String>{
      '9999999999999991': '{"version":1,"target":"[',
      '9999999999999992': '',
      '9999999999999993': '[1,2,3]',
      '9999999999999994': '{"version":1,"options":"nope"}',
    };

    Future<void> plantCorrupt() async {
      final String key = await keyPrefix();
      for (final MapEntry<String, String> entry in corrupt.entries) {
        await File(
          '${directory.path}/$key-${entry.key}.json',
        ).writeAsString(entry.value);
      }
    }

    test('恢复：跳过坏文件，用更早的有效备份还原映射', () async {
      await apply();
      await plantCorrupt();
      await service.restore(expected: (await service.read('Kiku'))!);
      expect(repo.settings.fieldMappings['Picture'], '{card-image}');
      expect(repo.definition.toJson(), baseline.toJson());
    });

    test('再次应用（改字段）：跳过坏文件，仍找得到原始映射备份', () async {
      await apply();
      await plantCorrupt();
      await apply('Other');
      expect(repo.settings.fieldMappings['Picture'], '{card-image}');
      expect(repo.settings.fieldMappings['Other'], '{card-video}');
    });

    test('恢复后重新启用：坏文件不影响读回上次恢复时的历史字段', () async {
      await apply();
      await apply('Other');
      await service.restore(expected: (await service.read('Kiku'))!);
      await plantCorrupt();
      await apply();
      expect(
        readAnkiVideoTemplateOptions(repo.definition)!.previousFields,
        <String>['Other'],
      );
    });

    // 审查补的形状：JSON 合法、options 也对，但原始映射的值不是字符串 / null。以前这种
    // 文件过得了读取，随后在取用处抛 TypeError，照样挡住应用 / 恢复。
    test('原始映射的值类型不对的备份同样跳过', () async {
      await apply();
      final File real = (await directory.list().toList())
          .whereType<File>()
          .single;
      final Map<String, dynamic> data =
          jsonDecode(await real.readAsString()) as Map<String, dynamic>;
      data['originalMappings'] = <String, Object?>{'Picture': 1};
      await File(
        '${directory.path}/${await keyPrefix()}-9999999999999995.json',
      ).writeAsString(jsonEncode(data));

      await apply('Other');
      expect(repo.settings.fieldMappings['Other'], '{card-video}');
      await service.restore(expected: (await service.read('Kiku'))!);
      expect(repo.settings.fieldMappings['Picture'], '{card-image}');
      expect(repo.definition.toJson(), baseline.toJson());
    });

    // 读取端现在会解析 options、校验映射值类型：钉住「当前写入格式的备份读得回来」。
    // 文件内容按磁盘上的样子逐字写死（不经 toJson），写入格式或读取校验任何一边漂了
    // 这条就红。原始映射的值可以是 null（应用前该字段没有映射）。
    test('当前格式的存量备份读得回来（含值为 null 的原始映射）', () async {
      repo.settings = repo.settings.copyWith(
        fieldMappings: <String, String>{'Audio': '{sentence-audio}'},
      );
      await apply();
      final File real = (await directory.list().toList())
          .whereType<File>()
          .single;
      final String target =
          (jsonDecode(await real.readAsString())
                  as Map<String, dynamic>)['target']
              as String;
      await real.writeAsString(
        '{"version":1,"target":${jsonEncode(target)},'
        '"definition":{},'
        '"originalMappings":{"Picture":null},'
        '"options":{"field":"Picture","placement":"bottom","autoplay":true,'
        '"previousFields":[]},'
        '"appliedFingerprint":"x","restoring":false}',
      );
      expect(repo.settings.fieldMappings['Picture'], '{card-video}');

      await service.restore(expected: (await service.read('Kiku'))!);
      expect(repo.settings.fieldMappings.containsKey('Picture'), isFalse);
      expect(repo.definition.toJson(), baseline.toJson());
    });

    test('只有坏文件时按「没有备份」报，不是 FormatException', () async {
      await apply();
      final String key = await keyPrefix();
      for (final FileSystemEntity entity in await directory.list().toList()) {
        await entity.delete();
      }
      await File(
        '${directory.path}/$key-9999999999999991.json',
      ).writeAsString('{"version":1,');
      await expectLater(
        service.restore(expected: (await service.read('Kiku'))!),
        throwsTemplate(AnkiVideoTemplateErrorCode.restoreBackupMissing),
      );
    });
  });

  group('备份键里的后端标识是冻结常量', () {
    Future<Map<String, dynamic>> backupOf(BaseAnkiRepository backend) async {
      service = AnkiVideoTemplateService(
        backend,
        backupDirectoryResolver: () async => directory,
      );
      await apply();
      final File file = (await directory.list().toList())
          .whereType<File>()
          .single;
      final Map<String, dynamic> data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // 文件名前缀 = sha256(target)：键变了，旧备份就按文件名匹配不上。
      expect(
        file.uri.pathSegments.last,
        startsWith('${sha256.convert(utf8.encode(data['target'] as String))}-'),
      );
      return data;
    }

    String backendKey(Map<String, dynamic> data) =>
        (jsonDecode(data['target'] as String) as List<dynamic>).first as String;

    // 这两个字符串是存量持久化值（已落在用户磁盘上的备份里），不能改。
    test('AnkiConnect 后端（含子类）= "AnkiConnectRepository"', () async {
      expect(
        backendKey(await backupOf(RenamedConnectRepository())),
        'AnkiConnectRepository',
      );
    });

    test('AnkiDroid 后端（含子类）= "AnkiRepository"', () async {
      expect(
        backendKey(await backupOf(RenamedDroidRepository())),
        'AnkiRepository',
      );
    });

    test('其余后端（测试替身）沿用类名', () async {
      expect(backendKey(await backupOf(FakeRepository())), 'FakeRepository');
    });
  });
}
