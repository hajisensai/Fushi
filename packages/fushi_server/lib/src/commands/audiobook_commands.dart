/// 离线有声书对齐：`audiobook align <bookKey> --audio <dir|file…> [--srt <file>]`。
///
/// 对一本**已在库的 EPUB**（书架上的文字书）配上音频 + 字幕，走引擎
/// `alignAndPersistAudiobook`——与 app 有声书导入对话框、服务端代下载的有声书入库
/// （`importDiscoveryAudiobook`）同一个对齐落库内核：解析章节 → 解析 cue → 正文匹配
/// → 字幕 / 音频拷进有声书持久目录 → 写 Audiobooks / SrtBook / cue / 健康度。
///
/// 已有有声书的书再跑一遍 = 换音频 / 换字幕（窄写入整组替换，不会残留旧 cue）。
/// 不做转录：没有字幕时先用 `fushi_server transcribe` 生成 SRT 再 `--srt` 喂进来。
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart' show kDiscoverySubtitleExtensions;
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart' show naturalCompare;
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/command_io.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

const String kAudiobookUsage = '''
audiobook align <bookKey> --audio <dir|file> [--audio …] [--srt <file>]
                                                     给已在库的 EPUB 配音频 + 字幕并对齐（--json 可用）''';

const String _kAlignUsageLine = 'audiobook align <bookKey> --audio <dir|file> [--audio …] [--srt <file>] [--json]';

bool _isAudio(String path) => AudiobookStorage.audioExtensions.contains(p.extension(path).toLowerCase());

bool _isSubtitle(String path) => kDiscoverySubtitleExtensions.contains(p.extension(path).toLowerCase());

/// `--audio` 的输入（目录 = 其下一层的音频与字幕文件；文件 = 它自己）展开成
/// 自然序的音频清单与目录里找到的字幕候选。
({List<String> audio, List<String> subtitles}) collectAudiobookInputs(List<String> inputs) {
  final List<String> audio = <String>[];
  final List<String> subtitles = <String>[];
  for (final String input in inputs) {
    if (FileSystemEntity.isDirectorySync(input)) {
      final List<String> files = <String>[
        for (final FileSystemEntity e in Directory(input).listSync(followLinks: false))
          if (e is File) e.path,
      ]..sort(naturalCompare);
      audio.addAll(files.where(_isAudio));
      subtitles.addAll(files.where(_isSubtitle));
    } else if (_isAudio(input)) {
      audio.add(input);
    }
  }
  return (audio: audio, subtitles: subtitles);
}

class AudiobookCommands extends CliModule {
  const AudiobookCommands({CommandIo io = const CommandIo()}) : _io = io;

  final CommandIo _io;

  @override
  List<String> get commands => const <String>['audiobook'];

  @override
  void register(ArgParser parser) {
    addJsonFlag(parser.addCommand('audiobook').addCommand('align'))
      ..addMultiOption('audio', help: '音频目录或文件（可重复；目录取其下一层的音频，自然序）')
      ..addOption('srt', help: '字幕（srt / vtt / lrc / ass）；缺省在 --audio 目录里找唯一一份');
  }

  @override
  String get usage => kAudiobookUsage;

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final ArgResults? leaf = command.command;
    if (leaf == null) return _io.usage('缺少子命令', _kAlignUsageLine);
    if (leaf.rest.length != 1) return _io.usage('要且只要一个 bookKey', _kAlignUsageLine);
    final String bookKey = leaf.rest.single;
    final List<String> audioInputs = <String>[
      for (final String raw in leaf['audio'] as List<String>) p.normalize(p.absolute(raw)),
    ];
    if (audioInputs.isEmpty) return _io.usage('缺少 --audio', _kAlignUsageLine);
    final String? srtArg = leaf['srt'] as String?;
    final String? srt = srtArg == null ? null : p.normalize(p.absolute(srtArg));
    final List<String> missing = <String>[
      for (final String path in <String>[...audioInputs, ?srt])
        if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) path,
    ];
    if (missing.isNotEmpty) {
      for (final String path in missing) {
        _io.err.writeln('找不到: $path');
      }
      return kExitNoInput;
    }
    for (final String input in audioInputs) {
      if (!FileSystemEntity.isDirectorySync(input) && !_isAudio(input)) {
        return _io.usage('不是音频文件: $input', _kAlignUsageLine);
      }
    }
    if (srt != null && !_isSubtitle(srt)) {
      return _io.usage('不是字幕文件: $srt（支持 ${kDiscoverySubtitleExtensions.join(' / ')}）', _kAlignUsageLine);
    }
    final ({List<String> audio, List<String> subtitles}) inputs = collectAudiobookInputs(audioInputs);
    if (inputs.audio.isEmpty) {
      _io.err.writeln('--audio 里没有音频文件（${AudiobookStorage.audioExtensions.join(' / ')}）');
      return kExitNoInput;
    }
    final String subtitle;
    if (srt != null) {
      subtitle = srt;
    } else if (inputs.subtitles.length == 1) {
      subtitle = inputs.subtitles.single;
    } else if (inputs.subtitles.isEmpty) {
      _io.err.writeln('--audio 目录里没有字幕：用 --srt 指定（没有字幕可先跑 fushi_server transcribe 生成）');
      return kExitNoInput;
    } else {
      return _io.usage('--audio 目录里有 ${inputs.subtitles.length} 份字幕，用 --srt 指定用哪一份', _kAlignUsageLine);
    }
    final bool json = wantsJson(leaf);
    return ctx.withRuntime((ServerRuntime rt) async {
      final EpubBookRow? row = await rt.db.getEpubBook(bookKey);
      if (row == null) {
        _io.err.writeln('库里没有这本书: $bookKey');
        return kExitNoInput;
      }
      if (BookFormat.parseOrEpub(row.format) != BookFormat.epub) {
        _io.err.writeln('$bookKey 不是 EPUB 文字书（format=${row.format}），不能配有声书');
        return kExitFailure;
      }
      final AudiobookAlignmentResult result = await alignAndPersistAudiobook(
        db: rt.db,
        repo: SrtBookRepository(rt.db),
        audiobookRepo: AudiobookRepository(rt.db),
        bookKey: bookKey,
        title: row.title,
        subtitlePath: subtitle,
        audioPaths: inputs.audio,
        onProgress: (double fraction, String message) =>
            _io.err.writeln('${(fraction * 100).round()}% $message'.trimRight()),
      );
      final AudiobookHealth health = result.health;
      if (json) {
        _io.json(<String, Object?>{
          'bookKey': bookKey,
          'subtitle': subtitle,
          'audio': result.persistedAudioPaths,
          'cueCount': result.cueCount,
          'health': health.kind.name,
          'matchRatePct': health.ratePct,
          if (health.reason != null) 'reason': health.reason,
        });
      } else {
        _io.out.writeln(
          '对齐完成: $bookKey  ${result.cueCount} 条 cue，${result.persistedAudioPaths.length} 个音频，'
          '健康度 ${health.kind.name}${health.ratePct == null ? '' : ' ${health.ratePct}%'}'
          '${health.reason == null ? '' : '（${health.reason}）'}',
        );
      }
      // 已落库，但匹配全失败的有声书不能当成功：脚本据此去换字幕 / 正文。
      return health.kind == HealthKind.failed ? kExitFailure : kExitOk;
    });
  }
}
