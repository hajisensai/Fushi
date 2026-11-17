// 不入库：用本机真实 Irodori 端到端跑 IrodoriBatchWorker（漫画有声遗留验证）。
// 用法：dart run tool/_irodori_e2e_driver.dart <输出目录>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker_script.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:path/path.dart' as p;

const String kPython = 'D:/APP/irodori/repo/.venv/Scripts/python.exe';
const String kRepo = 'D:/APP/irodori/repo';
const String kCheckpoint = 'D:/APP/irodori/models/v4-large/model.safetensors';
const String kCodec =
    'C:/Users/wrds/.cache/huggingface/hub/models--Aratako--Semantic-DACVAE-Japanese-32dim/snapshots/47376ee24834d7a05a48ebabfe3cde29b3c5e214/weights.pth';
const String kLora = 'D:/APP/irodori/release/shukura/lora';
const String kRefs = 'D:/APP/irodori/release/shukura/refs';
const String kFfmpeg = 'D:/APP/ffmpeg/bin/ffmpeg.exe';

List<String> refsOf(String speaker) {
  final List<String> files =
      Directory(p.join(kRefs, speaker))
          .listSync()
          .whereType<File>()
          .map((File f) => f.path.replaceAll('\\', '/'))
          .where((String f) => f.endsWith('.wav'))
          .toList()
        ..sort();
  return files;
}

/// 与 fushi/lib/src/media/manga/audio/manga_audio_render_backend.dart 的
/// buildMangaLineEncodeArgs 逐字相同（app 包依赖 Flutter，纯 Dart 脚本 import 不了）。
const String kMangaTrimFilter =
    'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,'
    'areverse,'
    'silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,'
    'areverse';

List<String> buildMangaLineEncodeArgs({
  required List<String> inputs,
  required String outputPath,
}) {
  final StringBuffer graph = StringBuffer();
  for (int i = 0; i < inputs.length; i++) {
    graph.write(
      '[$i:a]aresample=44100,'
      'aformat=sample_fmts=fltp:channel_layouts=mono[a$i];',
    );
  }
  for (int i = 0; i < inputs.length; i++) {
    graph.write('[a$i]');
  }
  graph.write(
    'concat=n=${inputs.length}:v=0:a=1[c];[c]$kMangaTrimFilter[out]',
  );
  return <String>[
    '-y',
    for (final String input in inputs) ...<String>['-i', input],
    '-filter_complex',
    graph.toString(),
    '-map',
    '[out]',
    '-vn',
    '-ac',
    '1',
    '-c:a',
    'aac',
    '-b:a',
    '96k',
    '-f',
    'mp4',
    outputPath,
  ];
}

Future<double?> probeSeconds(String path) async {
  final ProcessResult r = await Process.run(kFfmpeg, <String>['-i', path]);
  final RegExpMatch? m = RegExp(
    r'Duration: (\d+):(\d+):(\d+\.\d+)',
  ).firstMatch(r.stderr as String);
  if (m == null) return null;
  return int.parse(m[1]!) * 3600 +
      int.parse(m[2]!) * 60 +
      double.parse(m[3]!);
}

String sha(String path) {
  final List<int> b = File(path).readAsBytesSync();
  // 简单指纹：长度 + FNV-1a。
  int h = 0x811c9dc5;
  for (final int x in b) {
    h = ((h ^ x) * 0x01000193) & 0xffffffff;
  }
  return '${b.length}:${h.toRadixString(16)}';
}

Future<void> main(List<String> args) async {
  final String outDir = args.single;
  await Directory(outDir).create(recursive: true);
  final String workerDir = p.join(outDir, 'worker');
  await Directory(workerDir).create(recursive: true);
  final String script = p.join(workerDir, kIrodoriBatchWorkerScriptName);
  await File(script).writeAsString(kIrodoriBatchWorkerScript, flush: true);

  final List<int> pids = <int>[];
  final IrodoriBatchWorker worker = IrodoriBatchWorker(
    launch: () async => IrodoriBatchLaunch(
      executable: kPython,
      // 与 irodoriBatchLaunch 相同的参数形状，路径换成本机布局。
      arguments: <String>[
        '-X',
        'utf8',
        '-u',
        script,
        '--checkpoint',
        kCheckpoint,
        '--codec',
        kCodec,
        '--device',
        'auto',
      ],
      workingDirectory: workerDir,
      environment: <String, String>{
        'IRODORI_SDPA_CUDNN': '0',
        'HF_HUB_DISABLE_TELEMETRY': '1',
        'HF_HUB_OFFLINE': '1',
        'PYTHONUTF8': '1',
        'PYTHONIOENCODING': 'utf-8',
        'PYTHONNOUSERSITE': '1',
        // 本机开发 venv 没把 irodori_tts 装进 site-packages（app 安装器会装）。
        'PYTHONPATH': kRepo,
        'PYTHONHOME': '',
      },
    ),
    spawn:
        (
          String exe,
          List<String> a, {
          String? workingDirectory,
          Map<String, String>? environment,
        }) async {
          final Process proc = await HelperProcessRegistry.instance.start(
            exe,
            a,
            workingDirectory: workingDirectory,
            environment: environment,
          );
          pids.add(proc.pid);
          stdout.writeln('[driver] spawned pid ${proc.pid}');
          return proc;
        },
  );
  worker.addListener(() {
    stdout.writeln(
      '[driver] phase=${worker.phase.name} stage=${worker.loadingStage} '
      'device=${worker.device} failure=${worker.failure?.name} '
      'done=${worker.done}/${worker.total}',
    );
  });

  const IrodoriVoicePack loraPack = IrodoriVoicePack(
    id: 'e2e_lora',
    character: 'A',
    adapterDir: kLora,
    groups: <IrodoriRefGroup>[],
  );
  const IrodoriVoicePack basePack = IrodoriVoicePack(
    id: 'e2e_base',
    character: 'B',
    groups: <IrodoriRefGroup>[],
  );
  final IrodoriRefGroup miyagi = IrodoriRefGroup(
    name: 'miyagi',
    files: refsOf('miyagi'),
  );
  final IrodoriRefGroup sendai = IrodoriRefGroup(
    name: 'sendai',
    files: refsOf('sendai'),
  );
  String o(String id) => p.join(outDir, 'wav', '$id.wav').replaceAll('\\', '/');

  const String longText =
      '昨日は朝から雨が降っていたので、駅まで歩くのをやめてバスに乗りましたが、道がとても混んでいて会社に着いたのは十時過ぎでした。';
  const String midText = '週末は図書館に行って、ゆっくり本を読もうと思っています。';
  const String short1 = 'おはようございます。';
  const String short2 = '今日はいい天気ですね。';
  const String seedText = 'お茶をもう一杯いかがですか。';

  final List<IrodoriBatchItem> items = <IrodoriBatchItem>[
    // 不挂 LoRA 的短句（短句规则给定时长）。
    IrodoriBatchItem.forPack(
      id: 'base_short1',
      text: short1,
      pack: basePack,
      group: miyagi,
      outputPath: o('base_short1'),
    ),
    IrodoriBatchItem.forPack(
      id: 'base_short2',
      text: short2,
      pack: basePack,
      group: sendai,
      outputPath: o('base_short2'),
    ),
    // 对照：同一短句不给定时长（交给时长预测），看是否念两遍 / 时长偏长。
    IrodoriBatchItem(
      id: 'base_short1_predicted',
      text: short1,
      refs: miyagi.files,
      outputPath: o('base_short1_predicted'),
    ),
    // 挂 LoRA。
    IrodoriBatchItem.forPack(
      id: 'lora_long',
      text: longText,
      pack: loraPack,
      group: miyagi,
      outputPath: o('lora_long'),
    ),
    IrodoriBatchItem.forPack(
      id: 'lora_mid',
      text: midText,
      pack: loraPack,
      group: sendai,
      outputPath: o('lora_mid'),
    ),
    // 同 seed 两次。
    IrodoriBatchItem.forPack(
      id: 'seed42_a',
      text: seedText,
      pack: loraPack,
      group: miyagi,
      seed: 42,
      outputPath: o('seed42_a'),
    ),
    IrodoriBatchItem.forPack(
      id: 'seed42_b',
      text: seedText,
      pack: loraPack,
      group: miyagi,
      seed: 42,
      outputPath: o('seed42_b'),
    ),
    // 坏参数：参考音频不存在。
    IrodoriBatchItem(
      id: 'bad_ref',
      text: short2,
      refs: const <String>['D:/APP/irodori/release/shukura/refs/nope.wav'],
      outputPath: o('bad_ref'),
    ),
  ];
  stdout.writeln('[driver] order: '
      '${irodoriBatchOrder(items).map((IrodoriBatchItem i) => i.id).join(', ')}');
  for (final IrodoriBatchItem i in items) {
    stdout.writeln(
      '[driver] item ${i.id} chars=${irodoriSpokenCharCount(i.text)} '
      'seconds=${i.seconds} seed=${i.seed} lora=${i.adapterDir != null}',
    );
  }

  final Stopwatch total = Stopwatch()..start();
  final Stopwatch startSw = Stopwatch()..start();
  final bool ok = await worker.start();
  startSw.stop();
  stdout.writeln('[driver] start ok=$ok in ${startSw.elapsedMilliseconds} ms');
  if (!ok) {
    stdout.writeln(worker.logTail.join('\n'));
    await worker.stop();
    exitCode = 2;
    return;
  }
  final Map<String, int> lineAt = <String, int>{};
  final Stopwatch jobSw = Stopwatch()..start();
  final IrodoriBatchResult r = await worker.run(
    IrodoriBatchJob(id: 'e2e1', items: items),
    onLine: (IrodoriBatchLineResult l) {
      lineAt[l.id] = jobSw.elapsedMilliseconds;
      stdout.writeln(
        '[driver] line ${l.id} ok=${l.ok} dur=${l.durationMs} '
        't=${jobSw.elapsedMilliseconds} err=${l.error}',
      );
    },
  );
  jobSw.stop();
  stdout.writeln(
    '[driver] job done in ${jobSw.elapsedMilliseconds} ms '
    'cancelled=${r.cancelled} failure=${r.failure}',
  );

  // 第二个任务：同一进程复用（不重新加载模型）。
  final Stopwatch job2Sw = Stopwatch()..start();
  final IrodoriBatchResult r2 = await worker.run(
    IrodoriBatchJob(
      id: 'e2e2',
      items: <IrodoriBatchItem>[
        IrodoriBatchItem.forPack(
          id: 'seed42_c',
          text: seedText,
          pack: loraPack,
          group: miyagi,
          seed: 42,
          outputPath: o('seed42_c'),
        ),
      ],
    ),
  );
  job2Sw.stop();
  stdout.writeln(
    '[driver] job2 done in ${job2Sw.elapsedMilliseconds} ms '
    'ok=${r2.lines['seed42_c']?.ok} dur=${r2.lines['seed42_c']?.durationMs} '
    'pids=$pids',
  );

  // 转 m4a（与漫画渲染后端同一套 ffmpeg 参数）。
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  final Map<String, IrodoriBatchLineResult> all = <String, IrodoriBatchLineResult>{
    ...r.lines,
    ...r2.lines,
  };
  int prev = 0;
  for (final IrodoriBatchItem i in <IrodoriBatchItem>[
    ...irodoriBatchOrder(items),
    r2.lines.isEmpty ? items.first : IrodoriBatchItem.forPack(
      id: 'seed42_c',
      text: seedText,
      pack: loraPack,
      group: miyagi,
      seed: 42,
      outputPath: o('seed42_c'),
    ),
  ]) {
    final IrodoriBatchLineResult? l = all[i.id];
    final int at = lineAt[i.id] ?? 0;
    final int elapsed = i.id == 'seed42_c'
        ? job2Sw.elapsedMilliseconds
        : at - prev;
    if (i.id != 'seed42_c') prev = at;
    double? m4aSec;
    String? wavFp;
    if (l != null && l.ok && l.outputPath != null) {
      final String m4a = p.join(outDir, 'm4a', '${i.id}.m4a');
      await Directory(p.dirname(m4a)).create(recursive: true);
      final ProcessResult enc = await Process.run(
        kFfmpeg,
        buildMangaLineEncodeArgs(inputs: <String>[l.outputPath!], outputPath: m4a),
      );
      if (enc.exitCode == 0) m4aSec = await probeSeconds(m4a);
      wavFp = sha(l.outputPath!);
    }
    rows.add(<String, Object?>{
      'id': i.id,
      'chars': irodoriSpokenCharCount(i.text),
      'lora': i.adapterDir != null,
      'seconds_req': i.seconds,
      'seed': i.seed,
      'ok': l?.ok,
      'wall_ms': elapsed,
      'wav_ms': l?.durationMs,
      'm4a_s': m4aSec,
      'wav_fp': wavFp,
      'error': l?.error,
    });
  }
  File(p.join(outDir, 'results.json')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'start_ms': startSw.elapsedMilliseconds,
      'job1_ms': jobSw.elapsedMilliseconds,
      'job2_ms': job2Sw.elapsedMilliseconds,
      'device': worker.device,
      'rows': rows,
    }),
  );
  for (final Map<String, Object?> row in rows) {
    stdout.writeln('[row] ${jsonEncode(row)}');
  }

  final Stopwatch stopSw = Stopwatch()..start();
  await worker.stop();
  stopSw.stop();
  stdout.writeln(
    '[driver] stopped in ${stopSw.elapsedMilliseconds} ms phase=${worker.phase.name} '
    'total=${total.elapsedMilliseconds} ms pids=$pids',
  );
  File(p.join(outDir, 'worker_log_tail.txt'))
      .writeAsStringSync(worker.logTail.join('\n'));
  worker.dispose();
}
