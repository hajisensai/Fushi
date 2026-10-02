import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/video/bluray/bluray_playlist.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart';

/// A command-scoped concat manifest. Dispose only after the backend completes.
class BlurayFfmpegInput {
  BlurayFfmpegInput(this.args, this._directory);

  final List<String> args;
  final Directory? _directory;

  /// Cleanup never changes the command outcome: a manifest dir that is briefly
  /// locked (AV scanner, a Kit session still winding down) is only logged.
  Future<void> dispose() async {
    final Directory? directory = _directory;
    if (directory == null) return;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException catch (e) {
      engineLog.logDiagnostic('BlurayFfmpegInput.dispose', e);
    }
  }
}

/// Adapts MPLS inputs without materializing an entire disc as a temporary video.
/// Each input seek/window is folded into its playlist before opening FFmpeg, so
/// independently sought video/audio inputs still start on the same zero axis.
Future<BlurayFfmpegInput> prepareBlurayFfmpegArgs(
  List<String> args, {
  bool probe = false,
  Future<String> Function(String)? resolveStream,
}) async {
  final List<int> paths = <int>[
    for (int i = 0; i < args.length; i++)
      if (isBlurayPlaylistPath(args[i]) &&
          ((i > 0 && args[i - 1] == '-i') || (probe && i == args.length - 1)))
        i,
  ];
  if (paths.isEmpty) return BlurayFfmpegInput(args, null);
  final Directory temp = await Directory.systemTemp.createTemp('fushi-mpls-');
  try {
    final List<String> rewritten = <String>[];
    final Map<int, double> playlistInputs = <int, double>{};
    final int lastInput = args.lastIndexOf('-i');
    final List<String> maps = <String>[
      for (int i = lastInput + 2; i + 1 < args.length; i++)
        if (args[i] == '-map') args[i + 1],
    ];
    final bool decode =
        !probe &&
        lastInput >= 0 &&
        lastInput + 2 < args.length &&
        (maps.isEmpty ||
            maps.any(
              (String map) =>
                  map.startsWith('[') ||
                  RegExp(r'^\d+:[va](?::|\?|$)').hasMatch(map),
            ));
    int cursor = 0;
    int inputIndex = 0;
    for (int i = 0; i < args.length; i++) {
      final bool explicit = args[i] == '-i' && i + 1 < args.length;
      final bool bare = probe && paths.contains(i) && !explicit;
      if (!explicit && !bare) continue;
      final int pathIndex = explicit ? i + 1 : i;
      final List<String> options = args.sublist(cursor, i);
      if (paths.contains(pathIndex)) {
        double start = 0;
        double? duration;
        for (int j = 0; j + 1 < options.length; j++) {
          if (options[j] == '-ss' || options[j] == '-t') {
            final double value = _seconds(options[j + 1]);
            if (options[j] == '-ss') start = value;
            if (options[j] == '-t') duration = value;
            options.removeRange(j, j + 2);
            j--;
          }
        }
        final File manifest = File(p.join(temp.path, '$inputIndex.ffconcat'));
        final (String, double) contents = await _manifest(
          args[pathIndex],
          start,
          duration,
          decode: decode,
          resolveStream: resolveStream,
        );
        await manifest.writeAsString(contents.$1);
        rewritten.addAll(<String>[
          ...options,
          if (resolveStream != null) ...<String>[
            '-protocol_whitelist',
            'file,http,tcp',
          ],
          '-f',
          'concat',
          '-safe',
          '0',
          if (explicit) '-i',
          manifest.path,
        ]);
        playlistInputs[inputIndex] = contents.$2;
      } else {
        // Mining first renders the selected sentence to an independent AAC
        // file, then combines it with the original video window. This input
        // deliberately owns a fresh audio timeline; _addFilters rebases it.
        final bool independentAudio =
            maps.any((String map) => map.startsWith('$inputIndex:a')) &&
            !maps.any(
              (String map) =>
                  map == '$inputIndex' || map.startsWith('$inputIndex:v'),
            );
        if (!independentAudio &&
            !<String>{
              '.png',
              '.jpg',
              '.jpeg',
              '.srt',
              '.ass',
              '.vtt',
            }.contains(p.extension(args[pathIndex]).toLowerCase())) {
          throw UnsupportedError(
            'Ordinary media mixed with a playlist requires an explicit audio-only map',
          );
        }
        rewritten.addAll(<String>[...options, '-i', args[pathIndex]]);
      }
      inputIndex++;
      cursor = pathIndex + 1;
      i = pathIndex;
    }
    final List<String> output = args.sublist(cursor);
    if (decode) {
      _addFilters(output, playlistInputs);
      rewritten.insert(0, '-copyts');
    }
    rewritten.addAll(output);
    return BlurayFfmpegInput(rewritten, temp);
  } catch (_) {
    await temp.delete(recursive: true);
    rethrow;
  }
}

double _seconds(String value) {
  double result = 0;
  for (final String part in value.split(':')) {
    result = result * 60 + double.parse(part);
  }
  if (!result.isFinite || result < 0) {
    throw FormatException('Invalid playlist time', value);
  }
  return result;
}

Future<(String, double)> _manifest(
  String path,
  double start,
  double? duration, {
  required bool decode,
  Future<String> Function(String)? resolveStream,
}) async {
  final String? root = blurayDiscRootForPlaylistPath(path);
  final BlurayPlaylist? playlist = parseBlurayPlaylist(
    await File(path).readAsBytes(),
    id: p.basenameWithoutExtension(path),
  );
  if (root == null || playlist == null) {
    throw FormatException('Invalid Blu-ray playlist', path);
  }
  final StringBuffer text = StringBuffer('ffconcat version 1.0\n');
  double offset = 0;
  final List<(String, double, double)> clips = <(String, double, double)>[];
  double preroll = 0;
  final double end = duration == null ? double.infinity : start + duration;
  for (final BlurayClipRef clip in playlist.clips) {
    final double length = clip.durationTicks / kBlurayTimeScale;
    final double from = start > offset ? start - offset : 0;
    final double to = end < offset + length ? end - offset : length;
    offset += length;
    if (to <= from) continue;
    final String stream = p.absolute(
      p.join(root, 'BDMV', 'STREAM', clip.streamFileName),
    );
    if (!await File(stream).exists()) {
      throw FileSystemException('Missing Blu-ray playlist clip', stream);
    }
    if (stream.contains('\n') || stream.contains('\r')) {
      throw FormatException(
        'Newlines are not supported in concat paths',
        stream,
      );
    }
    final String input = resolveStream == null
        ? stream
        : await resolveStream(stream);
    final String escaped = input.replaceAll('\\', '/').replaceAll("'", "'\\''");
    final double origin = clip.inTimeTicks / kBlurayTimeScale;
    clips.add((escaped, origin + from, origin + to));
    if (decode && origin + from > preroll) preroll = origin + from;
  }
  if (clips.isEmpty) {
    throw RangeError('Requested window is outside the playlist');
  }
  double position = 0;
  for (final (String escaped, double from, double to) in clips) {
    // MPEG-TS binary seeks do not guarantee an earlier keyframe. Decode from
    // the physical beginning until CLPI CPI indexing is implemented. A common
    // timestamp offset keeps all selected sections on one continuous axis.
    text
      ..writeln("file '$escaped'")
      ..writeln('inpoint ${(from - preroll).toStringAsFixed(9)}')
      ..writeln('outpoint ${to.toStringAsFixed(9)}')
      ..writeln('duration ${(to - from).toStringAsFixed(9)}')
      ..writeln(
        'file_packet_meta lavf.concatdec.start_time ${((position + preroll) * 1000000).round()}',
      )
      ..writeln(
        'file_packet_meta lavf.concatdec.duration ${((to - from) * 1000000).round()}',
      );
    position += to - from;
  }
  return (text.toString(), preroll);
}

void _addFilters(List<String> output, Map<int, double> inputs) {
  // concat demuxer emits keyframe preroll and packets spanning edit boundaries.
  // Preserve original timestamps until select can consult the packet metadata.
  String prefix(String kind, int input) => inputs.containsKey(input)
      ? '${kind == 'v' ? 'select' : 'aselect'}=concatdec_select,'
            '${kind == 'v' ? 'setpts' : 'asetpts'}=PTS-${inputs[input]!.toStringAsFixed(9)}/TB'
      : '${kind == 'v' ? 'setpts' : 'asetpts'}=PTS-STARTPTS';
  final int complex = output.indexOf('-filter_complex');
  final Set<String> complexKinds = <String>{};
  if (complex >= 0) {
    String graph = output[complex + 1];
    if (!graph.startsWith('[')) {
      graph = '${prefix('v', 0)},$graph';
      complexKinds.add('v');
    } else {
      int label = 0;
      final List<String> heads = <String>[];
      graph = graph.replaceAllMapped(RegExp(r'\[(\d+):([va])(?::\d+)?\]'), (
        Match match,
      ) {
        if (!inputs.containsKey(int.parse(match.group(1)!))) return match[0]!;
        final String kind = match.group(2)!;
        complexKinds.add(kind);
        final String name = 'bd_input_${label++}';
        heads.add(
          '${match[0]}${prefix(kind, int.parse(match.group(1)!))}[$name]',
        );
        return '[$name]';
      });
      graph = <String>[...heads, graph].join(';');
    }
    output[complex + 1] = graph;
  }
  final List<String> maps = <String>[
    for (int i = 0; i + 1 < output.length; i++)
      if (output[i] == '-map') output[i + 1],
  ];
  for (final String kind in <String>['v', 'a']) {
    if (complexKinds.contains(kind) ||
        output.contains(kind == 'v' ? '-vn' : '-an')) {
      continue;
    }
    final List<String> matching = maps
        .where((String m) => RegExp('^\\d+:$kind(?::|\\?|\$)').hasMatch(m))
        .toList();
    if (maps.isNotEmpty && matching.isEmpty) continue;
    final int input = matching.isEmpty
        ? 0
        : int.parse(matching.first.split(':').first);
    final String chain = prefix(kind, input);
    final int filter = output.indexOf(kind == 'v' ? '-vf' : '-af');
    if (filter >= 0) {
      output[filter + 1] = '$chain,${output[filter + 1]}';
    } else {
      output.insertAll(0, <String>[kind == 'v' ? '-vf' : '-af', chain]);
    }
  }
}
