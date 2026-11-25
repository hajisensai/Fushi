import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/anki/delegating_anki_repository.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

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

  /// 备份查找键里的后端标识。**冻结的持久化值**：它进 [_target]，[_target] 的哈希是
  /// 备份文件名前缀、原文是备份里的 `target` 字段，改掉任何一个字符 = 现有用户的全部
  /// 备份立刻匹配不上（「找不到原始映射备份」，已适配的模板既不能改设置也不能恢复）。
  /// 取值是当初直接用 `runtimeType.toString()` 时两个可编辑后端的类名，写死之后类
  /// 改名 / 抽子类 / 混淆都不再影响已有备份。
  static const String _ankiConnectBackendKey = 'AnkiConnectRepository';
  static const String _ankiDroidBackendKey = 'AnkiRepository';

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
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.targetChanged,
      );
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
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.audioMappingRequired,
      );
    }
    final String? mapping = settings.fieldMappings[options.field];
    if (mapping != null &&
        mapping.trim().isNotEmpty &&
        !<String>{
          ...AnkiHandlebarOptions.cardImageTokens,
          _videoMapping,
        }.contains(mapping.trim())) {
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.fieldHasOtherContent,
      );
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
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.applyBackupMissing,
      );
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
    if (options == null) {
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.noVideoBlock,
      );
    }
    final String target = _target(settings);
    final Map<String, dynamic>? backup = await _findBackup(target, options);
    if (backup == null) {
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.restoreBackupMissing,
      );
    }
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
    if (!supportsEditing) {
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.hostOnly,
      );
    }
    final AnkiSettings settings = await _repository.loadSettings();
    final String? readTarget = target ?? _readTargets[expected];
    if (readTarget == null) {
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.rereadRequired,
      );
    }
    _checkTarget(settings, expected, readTarget);
    final AnkiNoteTypeDefinition? current = await read(expected.name);
    if (current == null || _fingerprint(current) != _fingerprint(expected)) {
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.templateChanged,
      );
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
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.targetChanged,
      );
    }
  }

  /// 两个可编辑后端用冻结的常量；其余（目前只有测试替身——别的后端都不支持编辑笔记
  /// 类型，走不到写备份）沿用类名。新增可编辑后端时在这里给它一个常量。
  String get _backendKey => switch (_repository) {
    AnkiConnectRepository() => _ankiConnectBackendKey,
    AnkiRepository() => _ankiDroidBackendKey,
    _ => _repository.runtimeType.toString(),
  };

  String _target(AnkiSettings settings) => jsonEncode(<Object?>[
    _backendKey,
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
        throw const AnkiVideoTemplateException(
          AnkiVideoTemplateErrorCode.writeRejected,
        );
      }
      final AnkiNoteTypeDefinition? written = await read(after.name);
      if (written == null || _fingerprint(written) != _fingerprint(after)) {
        throw const AnkiVideoTemplateException(
          AnkiVideoTemplateErrorCode.writeVerificationFailed,
        );
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
            throw const AnkiVideoTemplateException(
              AnkiVideoTemplateErrorCode.mappingsChanged,
            );
          }
          _setMapping(merged, key, mappings[key]);
        }
        return current.copyWith(fieldMappings: merged);
      });
      final AnkiSettings saved = await _repository.loadSettings();
      _checkTarget(saved, before, target);
      final AnkiNoteTypeDefinition? verified = await read(after.name);
      if (verified == null || _fingerprint(verified) != _fingerprint(after)) {
        throw const AnkiVideoTemplateException(
          AnkiVideoTemplateErrorCode.templateChangedDuringApply,
        );
      }
      for (final String key in <String>{
        ...settings.fieldMappings.keys,
        ...mappings.keys,
      }) {
        if (settings.fieldMappings[key] != mappings[key] &&
            saved.fieldMappings[key] != mappings[key]) {
          throw const AnkiVideoTemplateException(
            AnkiVideoTemplateErrorCode.mappingVerificationFailed,
          );
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
          // 两个内层错误都原样带出去：原始失败决定用户该怎么办，回滚失败说明现场
          // 停在哪。拼成一句字符串就丢了类型，上层没法分别本地化。
          throw AnkiVideoTemplateException(
            AnkiVideoTemplateErrorCode.rollbackIncomplete,
            cause: error,
            rollbackCause: rollbackError,
          );
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
    if (current == null) {
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.rollbackUnreadable,
      );
    }
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
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.rollbackRejected,
      );
    }
    final AnkiNoteTypeDefinition? verified = await read(before.name);
    if (verified == null ||
        rollback.any(
          (AnkiCardTemplate expected) => !verified.templates.any(
            (AnkiCardTemplate card) =>
                card.name == expected.name && _sameCard(card, expected),
          ),
        )) {
      throw const AnkiVideoTemplateException(
        AnkiVideoTemplateErrorCode.rollbackVerificationFailed,
      );
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

  /// [target] 的全部可读备份，新的在前。
  ///
  /// 逐文件读：一份读不出来 / 不是合法 JSON / 形状不对的备份（写到一半进程被杀、磁盘
  /// 满）只跳过并记一条日志，不让它挡住更早的有效备份——以前这里没有 try，一个坏文件
  /// 就让之后每次应用 / 恢复都抛 `FormatException`，只能手动去删（BUG-4826）。
  Stream<Map<String, dynamic>> _backups(String target) async* {
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
      final Map<String, dynamic>? data = await _readBackup(file);
      if (data != null && data['target'] == target) yield data;
    }
  }

  /// 读一份备份；坏的返回 null 并记一条诊断日志。形状也在这里验（`options` /
  /// `originalMappings` 是调用方要直接取用的两块，连同映射的值类型），调用方之后的
  /// 取用不会再因为形状抛错。
  ///
  /// `options` 必须过得了 [AnkiVideoTemplateOptions.fromJson]（`field` / `placement` /
  /// `autoplay` 齐全、`placement` 是认得的枚举名）。写入端一直是 `toJson()` 全字段，
  /// 存量备份都满足；**以后给 options 加字段必须在 `fromJson` 里给缺省值、枚举名不能
  /// 改**，否则旧备份会在这里被当成坏文件跳过，用户看到的是「找不到原始映射备份」。
  static Future<Map<String, dynamic>?> _readBackup(File file) async {
    try {
      final Object? data = jsonDecode(await file.readAsString());
      if (data is! Map<String, dynamic> || data['originalMappings'] is! Map) {
        throw const FormatException('not a video template backup');
      }
      Map<String, String?>.from(data['originalMappings'] as Map);
      AnkiVideoTemplateOptions.fromJson(
        data['options'] as Map<String, dynamic>,
      );
      return data;
    } on Object catch (error) {
      ErrorLogService.instance.logDiagnostic(
        'AnkiVideoTemplateService.backup',
        'skipped unreadable backup ${p.basename(file.path)}: $error',
      );
      return null;
    }
  }

  Future<Map<String, dynamic>?> _findBackup(
    String target,
    AnkiVideoTemplateOptions options,
  ) async {
    final String wanted = jsonEncode(_options(options));
    await for (final Map<String, dynamic> data in _backups(target)) {
      if (data['restoring'] != true && jsonEncode(data['options']) == wanted) {
        return data;
      }
    }
    return null;
  }

  Future<AnkiVideoTemplateOptions?> _latestRestoredOptions(
    String target,
  ) async {
    await for (final Map<String, dynamic> data in _backups(target)) {
      if (data['restoring'] == true) {
        return AnkiVideoTemplateOptions.fromJson(
          data['options'] as Map<String, dynamic>,
        );
      }
    }
    return null;
  }
}
