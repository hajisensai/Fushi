/// `fushi_server export <kind> <key> -o <file>`：把库里的一项资产打成同步资产包。
///
/// 包格式就是互联 / 云同步搬运用的那一份（`SyncAssetPackageService`），所以导出的
/// 文件可以在任一端经「导入同步资产包」原样落地。三种资产：
/// - `dictionary <词典名>` → `.fushidict`（词典元数据 + `<support>/dictionaries/<名>` 资源）；
/// - `audiobook <srtBook uid | bookKey>` → `.fushiaudiobook`（字幕书 + 音频 + cue）；
/// - `local-audio <displayName>` → `.fushiaudiolib`（本地音频库 .db + 子来源配置）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/models/local_audio_db_entry.dart';
import 'package:fushi_engine/sync/local_audio_library_store.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/server_language.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

const int _exitOk = 0;
const int _exitFailure = 1;
const int _exitUsage = 64;
const int _exitNoInput = 66;

/// 可导出的资产种类。
enum ExportKind {
  dictionary('dictionary'),
  audiobook('audiobook'),
  localAudio('local-audio');

  const ExportKind(this.arg);

  final String arg;

  static ExportKind? parse(String raw) {
    for (final ExportKind k in values) {
      if (k.arg == raw) return k;
    }
    return null;
  }
}

/// 找不到要导出的东西（→ 66）。
class ExportSourceMissing implements Exception {
  const ExportSourceMissing(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 导出一项资产到 [output]（已确认不存在）。返回写出的文件。
Future<File> exportSyncAsset({
  required FushiDatabase db,
  required SyncAssetPackageService packages,
  required ExportKind kind,
  required String key,
  required File output,
  required Directory dictionaryResourceRoot,
  required List<LocalAudioDbEntry> Function() localAudioEntries,
}) async {
  switch (kind) {
    case ExportKind.dictionary:
      final bool exists = (await db.getAllDictionaryMetadata()).any(
        (DictionaryMetaRow r) => r.name == key,
      );
      if (!exists) {
        throw ExportSourceMissing(
          tr('没有名为「$key」的词典', 'No dictionary named "$key"'),
        );
      }
      return packages.exportDictionaryPackage(
        dictionaryName: key,
        dictionaryResourceRoot: dictionaryResourceRoot,
        outputFile: output,
      );
    case ExportKind.audiobook:
      // 键既可以是字幕书 uid，也可以是它挂的 EPUB bookKey（app 两种身份都在用）。
      final SrtBookRow? book =
          await db.getSrtBookByUid(key) ?? await db.getSrtBookByBookKey(key);
      if (book == null) {
        throw ExportSourceMissing(
          tr(
            '没有 uid 或 bookKey 为「$key」的有声书',
            'No audiobook with uid or bookKey "$key"',
          ),
        );
      }
      return packages.exportAudioDatabasePackage(
        srtBookUid: book.uid,
        outputFile: output,
      );
    case ExportKind.localAudio:
      LocalAudioDbEntry? entry;
      for (final LocalAudioDbEntry e in localAudioEntries()) {
        if (e.displayName == key) entry = e;
      }
      if (entry == null) {
        throw ExportSourceMissing(
          tr('没有名为「$key」的本地音频库', 'No local audio library named "$key"'),
        );
      }
      final File dbFile = File(entry.path);
      if (!await dbFile.exists()) {
        throw ExportSourceMissing(
          tr(
            '本地音频库「$key」的数据库文件不在: ${entry.path}',
            'The database file of local audio library "$key" is missing: ${entry.path}',
          ),
        );
      }
      return packages.exportLocalAudioPackage(
        displayName: entry.displayName,
        enabled: entry.enabled,
        sources: entry.sources,
        dbFile: dbFile,
        outputFile: output,
      );
  }
}

class ExportModule extends CliModule {
  const ExportModule({this.out, this.err});

  final StringSink? out;
  final StringSink? err;

  @override
  List<String> get commands => const <String>['export'];

  @override
  void register(ArgParser parser) {
    parser.addCommand('export')
      ..addOption(
        'out',
        abbr: 'o',
        help: tr('输出文件路径（必填）', 'Output file path (required)'),
      )
      ..addFlag(
        'force',
        negatable: false,
        help: tr('覆盖已存在的输出文件', 'Overwrite an existing output file'),
      )
      ..addFlag('json', negatable: false, help: tr('输出 JSON', 'Output JSON'));
  }

  @override
  String get usage => tr(
    '''
export dictionary|audiobook|local-audio <key> -o <file> [--force] [--json]
    把一项资产打成同步资产包（与互联 / 云同步同一格式）：dictionary <词典名>、
    audiobook <字幕书 uid 或 bookKey>、local-audio <本地音频库名>''',
    '''
export dictionary|audiobook|local-audio <key> -o <file> [--force] [--json]
    Pack one asset into a sync asset bundle (same format as interconnect / cloud sync): dictionary <dictionary name>,
    audiobook <subtitled book uid or bookKey>, local-audio <local audio library name>''',
  );

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final StringSink o = out ?? stdout;
    final StringSink e = err ?? stderr;
    final List<String> rest = command.rest;
    final ExportKind? kind = rest.isEmpty ? null : ExportKind.parse(rest.first);
    final String? outPath = command['out'] as String?;
    if (rest.length != 2 ||
        kind == null ||
        outPath == null ||
        outPath.isEmpty) {
      e.writeln(
        tr(
          '用法: export dictionary|audiobook|local-audio <key> -o <file>',
          'Usage: export dictionary|audiobook|local-audio <key> -o <file>',
        ),
      );
      return _exitUsage;
    }
    final File output = File(p.absolute(outPath));
    if (await output.exists() && !(command['force'] as bool)) {
      e.writeln(
        tr(
          '已存在: ${output.path}（加 --force 覆盖）',
          'Already exists: ${output.path} (add --force to overwrite)',
        ),
      );
      return _exitFailure;
    }
    return ctx.withRuntime((ServerRuntime rt) async {
      // 先写到旁边的临时文件，成功后再换上去：--force 时导出中途失败不能把旧文件先删掉。
      final File partial = File('${output.path}.partial');
      final File written;
      try {
        await exportSyncAsset(
          db: rt.db,
          packages: SyncAssetPackageService(db: rt.db),
          kind: kind,
          key: rest[1],
          output: partial,
          dictionaryResourceRoot: rt.paths.dictionaryResources,
          localAudioEntries: () => LocalAudioLibraryStore(
            prefs: rt.prefs,
            databaseDirectory: rt.paths.support,
          ).entries,
        );
        written = await partial.rename(output.path);
      } on ExportSourceMissing catch (x) {
        e.writeln(x.message);
        return _exitNoInput;
      } finally {
        if (await partial.exists()) await partial.delete();
      }
      final int bytes = await written.length();
      if (command['json'] as bool) {
        o.writeln(
          jsonEncode(<String, Object?>{
            'kind': kind.arg,
            'key': rest[1],
            'file': written.path,
            'bytes': bytes,
          }),
        );
      } else {
        o.writeln(
          tr(
            '已导出 ${kind.arg} 「${rest[1]}」→ ${written.path}（$bytes 字节）',
            'Exported ${kind.arg} "${rest[1]}" -> ${written.path} ($bytes bytes)',
          ),
        );
      }
      return _exitOk;
    });
  }
}
