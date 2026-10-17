import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/anki/delegating_anki_repository.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// Explicit, backed-up video adaptation of the currently selected note type.
class AnkiVideoTemplateService {
  AnkiVideoTemplateService(
    BaseAnkiRepository repository, {
    Future<Directory> Function()? backupDirectoryResolver,
  }) : _repository = _unwrap(repository),
       _backupDirectoryResolver = backupDirectoryResolver;

  final BaseAnkiRepository _repository;
  final Future<Directory> Function()? _backupDirectoryResolver;
  static const String _videoMapping = '{card-video}';

  static BaseAnkiRepository _unwrap(BaseAnkiRepository repository) {
    while (repository is DelegatingAnkiRepository) {
      repository = repository.inner;
    }
    return repository;
  }

  bool get supportsEditing =>
      _repository is! RemoteMiningAnkiRepository &&
      _repository.supportsNoteTypeEditing;

  final Expando<String> _readTargets = Expando<String>();

  Future<AnkiNoteTypeDefinition?> read(String modelName) async {
    if (!supportsEditing) return null;
    final String target = _target(await _repository.loadSettings());
    final AnkiNoteTypeDefinition? definition = await _repository
        .readNoteTypeDefinition(modelName);
    if (target != _target(await _repository.loadSettings())) {
      throw StateError('制卡目标已改变，请重新打开预览。');
    }
    if (definition != null) _readTargets[definition] = target;
    return definition;
  }

  Future<void> apply({
    required AnkiNoteTypeDefinition expected,
    required AnkiVideoTemplateOptions options,
  }) async {
    final AnkiSettings settings = await _validate(expected);
    final String target = _target(settings);
    final List<MapEntry<String, String>> audioMappings = settings
        .fieldMappings
        .entries
        .where(
          (MapEntry<String, String> entry) =>
              entry.value.contains('{sentence-audio}'),
        )
        .toList();
    if (audioMappings.length != 1 ||
        audioMappings.single.key == options.field ||
        !expected.fields.contains(audioMappings.single.key) ||
        '{sentence-audio}'.allMatches(audioMappings.single.value).length != 1) {
      throw StateError('请仅在另一个字段映射一次句子音频，再启用视频适配。');
    }
    final String? mapping = settings.fieldMappings[options.field];
    if (mapping != null &&
        mapping.trim().isNotEmpty &&
        !<String>{
          ...AnkiHandlebarOptions.cardImageTokens,
          _videoMapping,
        }.contains(mapping.trim())) {
      throw StateError('所选字段包含其他内容，请选择图片、视频或空字段。');
    }
    final AnkiVideoTemplateOptions? old = readAnkiVideoTemplateOptions(
      expected,
    );
    // Disabling removes the player, not media from existing cards. Retain its
    // source fields when enabling again, while taking a fresh mapping baseline.
    final AnkiVideoTemplateOptions? restored = old == null
        ? await _latestRestoredOptions(target)
        : null;
    final AnkiVideoTemplateOptions effectiveOptions = AnkiVideoTemplateOptions(
      field: options.field,
      placement: options.placement,
      autoplay: options.autoplay,
      previousFields:
          <String>{
                ...options.previousFields,
                if (old != null) old.field,
                if (old != null) ...old.previousFields,
                if (restored != null) restored.field,
                if (restored != null) ...restored.previousFields,
              }
              .where(
                (String field) =>
                    field != options.field && expected.fields.contains(field),
              )
              .toList(),
    );
    final Map<String, dynamic>? previous = old == null
        ? null
        : await _findBackup(target, old);
    if (old != null && previous == null) {
      throw StateError('找不到此适配的原始映射备份，请先恢复模板后重试。');
    }
    final Map<String, String?> originals = previous == null
        ? <String, String?>{}
        : Map<String, String?>.from(previous['originalMappings'] as Map);
    originals.putIfAbsent(options.field, () => mapping);
    final Map<String, String> nextMappings = Map.of(settings.fieldMappings);
    if (old != null &&
        old.field != options.field &&
        nextMappings[old.field] == _videoMapping) {
      _setMapping(nextMappings, old.field, originals[old.field]);
    }
    nextMappings[options.field] = _videoMapping;
    final AnkiNoteTypeDefinition next = applyAnkiVideoTemplate(
      expected,
      effectiveOptions,
    );
    await _backup(expected, target, effectiveOptions, originals, next);
    await _validate(expected, target: target);
    await _write(expected, next, settings, nextMappings, target);
  }

  Future<void> restore({required AnkiNoteTypeDefinition expected}) async {
    final AnkiSettings settings = await _validate(expected);
    final AnkiVideoTemplateOptions? options =
        readAnkiVideoTemplateRecoveryOptions(expected);
    if (options == null) throw StateError('模板没有视频适配区块。');
    final String target = _target(settings);
    final Map<String, dynamic>? backup = await _findBackup(target, options);
    if (backup == null) throw StateError('找不到当前后端的原始映射备份。');
    final Map<String, String?> originals = Map<String, String?>.from(
      backup['originalMappings'] as Map,
    );
    final Map<String, String> mappings = Map.of(settings.fieldMappings);
    if (mappings[options.field] == _videoMapping) {
      _setMapping(mappings, options.field, originals[options.field]);
    }
    final AnkiNoteTypeDefinition next = removeAnkiVideoTemplate(expected);
    await _backup(expected, target, options, originals, next, restoring: true);
    await _validate(expected, target: target);
    await _write(expected, next, settings, mappings, target);
  }

  Future<AnkiSettings> _validate(
    AnkiNoteTypeDefinition expected, {
    String? target,
  }) async {
    if (!supportsEditing) throw UnsupportedError('请在制卡主机上修改视频模板。');
    final AnkiSettings settings = await _repository.loadSettings();
    final String? readTarget = target ?? _readTargets[expected];
    if (readTarget == null) {
      throw StateError('请重新读取当前后端的模板后再应用。');
    }
    _checkTarget(settings, expected, readTarget);
    final AnkiNoteTypeDefinition? current = await read(expected.name);
    if (current == null || _fingerprint(current) != _fingerprint(expected)) {
      throw StateError('Anki 模板已改变，请重新打开预览。');
    }
    return settings;
  }

  void _checkTarget(
    AnkiSettings settings,
    AnkiNoteTypeDefinition expected,
    String? target,
  ) {
    if (settings.selectedNoteType?.name != expected.name ||
        (target != null && _target(settings) != target)) {
      throw StateError('制卡目标已改变，请重新打开预览。');
    }
  }

  String _target(AnkiSettings settings) => jsonEncode(<Object?>[
    _repository.runtimeType.toString(),
    settings.ankiConnectHost,
    settings.ankiConnectPort,
    settings.ankiConnectUseHttps,
    settings.selectedNoteType?.id,
    settings.selectedNoteType?.name,
  ]);

  Future<void> _write(
    AnkiNoteTypeDefinition before,
    AnkiNoteTypeDefinition after,
    AnkiSettings settings,
    Map<String, String> mappings,
    String target,
  ) async {
    bool attempted = false;
    try {
      attempted = true;
      if (!await _repository.updateNoteTypeTemplates(
        after.name,
        after.templates,
      )) {
        throw StateError('后端拒绝写入模板。');
      }
      final AnkiNoteTypeDefinition? written = await read(after.name);
      if (written == null || _fingerprint(written) != _fingerprint(after)) {
        throw StateError('模板写入后校验失败，已保留恢复备份。');
      }
      await _repository.updateSettings((AnkiSettings current) {
        _checkTarget(current, before, target);
        final Map<String, String> merged = Map.of(current.fieldMappings);
        for (final String key in <String>{
          ...settings.fieldMappings.keys,
          ...mappings.keys,
        }) {
          if (settings.fieldMappings[key] == mappings[key]) continue;
          if (current.fieldMappings[key] != settings.fieldMappings[key]) {
            throw StateError('字段映射已改变，请重新打开预览。');
          }
          _setMapping(merged, key, mappings[key]);
        }
        return current.copyWith(fieldMappings: merged);
      });
      final AnkiSettings saved = await _repository.loadSettings();
      _checkTarget(saved, before, target);
      final AnkiNoteTypeDefinition? verified = await read(after.name);
      if (verified == null || _fingerprint(verified) != _fingerprint(after)) {
        throw StateError('模板在应用过程中改变，已保留恢复备份。');
      }
      for (final String key in <String>{
        ...settings.fieldMappings.keys,
        ...mappings.keys,
      }) {
        if (settings.fieldMappings[key] != mappings[key] &&
            saved.fieldMappings[key] != mappings[key]) {
          throw StateError('字段映射写入后校验失败，已保留恢复备份。');
        }
      }
    } catch (error) {
      if (attempted) {
        try {
          final AnkiSettings currentSettings = await _repository.loadSettings();
          _checkTarget(currentSettings, before, target);
          await _rollbackTemplates(before, after);
          await _repository.updateSettings((AnkiSettings current) {
            _checkTarget(current, before, target);
            final Map<String, String> restored = Map.of(current.fieldMappings);
            for (final String key in <String>{
              ...settings.fieldMappings.keys,
              ...mappings.keys,
            }) {
              if (settings.fieldMappings[key] != mappings[key] &&
                  current.fieldMappings[key] == mappings[key]) {
                _setMapping(restored, key, settings.fieldMappings[key]);
              }
            }
            return current.copyWith(fieldMappings: restored);
          });
        } catch (rollbackError) {
          throw StateError('$error；自动回滚未完成：$rollbackError。已保留磁盘备份。');
        }
      }
      rethrow;
    }
  }

  /// AnkiDroid can fail after writing only some card templates. Roll back only
  /// exact values written by this operation, preserving concurrent user edits.
  Future<void> _rollbackTemplates(
    AnkiNoteTypeDefinition before,
    AnkiNoteTypeDefinition after,
  ) async {
    final AnkiNoteTypeDefinition? current = await read(before.name);
    if (current == null) throw StateError('无法读取模板以校验回滚。');
    final Map<String, AnkiCardTemplate> originals = <String, AnkiCardTemplate>{
      for (final AnkiCardTemplate card in before.templates) card.name: card,
    };
    final Map<String, AnkiCardTemplate> applied = <String, AnkiCardTemplate>{
      for (final AnkiCardTemplate card in after.templates) card.name: card,
    };
    final List<AnkiCardTemplate> rollback = <AnkiCardTemplate>[];
    for (final AnkiCardTemplate card in current.templates) {
      final AnkiCardTemplate? original = originals[card.name];
      final AnkiCardTemplate? written = applied[card.name];
      if (original != null &&
          written != null &&
          _sameCard(card, written) &&
          !_sameCard(original, written)) {
        rollback.add(original);
      }
    }
    if (rollback.isEmpty) return;
    if (!await _repository.updateNoteTypeTemplates(before.name, rollback)) {
      throw StateError('后端拒绝回滚部分模板。');
    }
    final AnkiNoteTypeDefinition? verified = await read(before.name);
    if (verified == null ||
        rollback.any(
          (AnkiCardTemplate expected) => !verified.templates.any(
            (AnkiCardTemplate card) =>
                card.name == expected.name && _sameCard(card, expected),
          ),
        )) {
      throw StateError('部分模板回滚后的校验失败。');
    }
  }

  static bool _sameCard(AnkiCardTemplate a, AnkiCardTemplate b) =>
      a.front == b.front && a.back == b.back;

  static void _setMapping(
    Map<String, String> mappings,
    String field,
    String? value,
  ) {
    if (value == null) {
      mappings.remove(field);
    } else {
      mappings[field] = value;
    }
  }

  static String _fingerprint(AnkiNoteTypeDefinition definition) =>
      sha256.convert(utf8.encode(jsonEncode(definition.toJson()))).toString();

  static Map<String, dynamic> _options(AnkiVideoTemplateOptions options) =>
      options.toJson();

  Future<Directory> _directory() async {
    final Directory directory = _backupDirectoryResolver == null
        ? Directory(
            p.join(
              (await AppPaths.supportRootDirectory()).path,
              'backups',
              'video-templates',
            ),
          )
        : await _backupDirectoryResolver();
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _backup(
    AnkiNoteTypeDefinition before,
    String target,
    AnkiVideoTemplateOptions options,
    Map<String, String?> originals,
    AnkiNoteTypeDefinition after, {
    bool restoring = false,
  }) async {
    final Directory directory = await _directory();
    final String key = sha256.convert(utf8.encode(target)).toString();
    final File file = File(
      p.join(
        directory.path,
        '$key-${DateTime.now().microsecondsSinceEpoch}.json',
      ),
    );
    await file.writeAsString(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'target': target,
        'definition': before.toJson(),
        'originalMappings': originals,
        'options': _options(options),
        'appliedFingerprint': _fingerprint(after),
        'restoring': restoring,
      }),
      flush: true,
    );
  }

  Future<Map<String, dynamic>?> _findBackup(
    String target,
    AnkiVideoTemplateOptions options,
  ) async {
    final Directory directory = await _directory();
    final String key = sha256.convert(utf8.encode(target)).toString();
    final List<File> files =
        (await directory.list().toList())
            .whereType<File>()
            .where(
              (File file) =>
                  p.basename(file.path).startsWith('$key-') &&
                  file.path.endsWith('.json'),
            )
            .toList()
          ..sort((File a, File b) => b.path.compareTo(a.path));
    for (final File file in files) {
      final Map<String, dynamic> data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['target'] == target &&
          data['restoring'] != true &&
          jsonEncode(data['options']) == jsonEncode(_options(options))) {
        return data;
      }
    }
    return null;
  }

  Future<AnkiVideoTemplateOptions?> _latestRestoredOptions(
    String target,
  ) async {
    final Directory directory = await _directory();
    final String key = sha256.convert(utf8.encode(target)).toString();
    final List<File> files =
        (await directory.list().toList())
            .whereType<File>()
            .where(
              (File file) =>
                  p.basename(file.path).startsWith('$key-') &&
                  file.path.endsWith('.json'),
            )
            .toList()
          ..sort((File a, File b) => b.path.compareTo(a.path));
    for (final File file in files) {
      final Map<String, dynamic> data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['target'] == target && data['restoring'] == true) {
        return AnkiVideoTemplateOptions.fromJson(
          data['options'] as Map<String, dynamic>,
        );
      }
    }
    return null;
  }
}
