// 离线评测驱动：把一个 OCR 评测集（tool/ocr_bench/ 的 labels.jsonl + 图片）喂进
// 与 app 完全相同的本地 OCR 服务（MangaOcrServiceImpl，服务端 FFI ORT 接线），
// 逐图输出识别出的块 / 行 / 行框与耗时，供 tool/ocr_bench/score_pipeline.py 打分。
// 不碰数据库、不改模型；逐页缓存写在评测集目录下的 manga_ocr_out/。
//
//   dart run tool/ocr_pipeline_eval.dart --data <评测集目录> --server-data <数据根>
//       --out <preds.jsonl> [--mode page|text] [--band 0.78] [--ignore-furigana]
//
// --mode page：漫画整页管线（检测器 + 补检 + 逐块识别），即暂停 OCR「所有视频」
//   与漫画阅读器走的路径。
// --mode text：整图当一块文字图（PP 行检测 + 逐行识别），即图形字幕位图的路径；
//   --band 只取图片底部这一段（模拟字幕位图只含字幕区域）。
// 数据根下需有 support/ocr_models/manga-ctc/（app 已下载的模型复制过来即可）；
// ORT 库用 FUSHI_ORT_LIBRARY / ASR_ONNXRUNTIME_LIB 或 --ort 指定。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/manga_ocr_local_model.dart';
import 'package:fushi_engine/ocr/manga_ocr_service.dart';
import 'package:fushi_engine/ocr/manga_ocr_service_impl.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) async {
  final ArgParser parser = ArgParser()
    ..addOption('data', mandatory: true)
    ..addOption('server-data', mandatory: true)
    ..addOption('out', mandatory: true)
    ..addOption('mode', allowed: <String>['page', 'text'], defaultsTo: 'page')
    ..addOption('band', defaultsTo: '0')
    ..addOption('ort')
    ..addFlag('ignore-furigana');
  final ArgResults args = parser.parse(argv);
  final String dataDir = p.absolute(args['data'] as String);
  final ServerPaths paths = ServerPaths(
    p.absolute(args['server-data'] as String),
  );
  await paths.ensureLayout();
  final ServerConfig config = ServerConfig.defaults(
    dataDir: paths.dataDir,
  ).copyWith(ortLibraryPath: args['ort'] as String?);
  final ServerLog log = ServerLog(
    file: File(p.join(paths.logs.path, 'ocr_pipeline_eval.log')),
  );
  await log.open();
  installServerHostBindings(config: config, paths: paths, log: log);

  final bool ignoreFurigana = args['ignore-furigana'] as bool;
  final MangaOcrServiceImpl service = MangaOcrServiceImpl(
    localModel: kDefaultMangaOcrLocalModel,
    ignoreFurigana: () => ignoreFurigana,
  );
  if (!(await service.modelStatus()).allReady) {
    stderr.writeln(
      '模型不齐：把 app 的 ocr_models/manga-ctc 复制到 '
      '${p.join(paths.support.path, 'ocr_models', 'manga-ctc')}',
    );
    exitCode = 69;
    return;
  }
  final List<Map<String, Object?>> records = <Map<String, Object?>>[
    for (final String line in File(
      p.join(dataDir, 'labels.jsonl'),
    ).readAsLinesSync())
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, Object?>,
  ];
  final IOSink out = File(args['out'] as String).openWrite();
  final String mode = args['mode'] as String;
  try {
    if (mode == 'page') {
      await _pageMode(service, dataDir, records, out);
    } else {
      await _textMode(
        service,
        dataDir,
        records,
        out,
        double.parse(args['band'] as String),
      );
    }
  } finally {
    await out.close();
    await log.close();
  }
}

Map<String, Object?> _rect(OcrRect r) => <String, Object?>{
  'box': <double>[r.left, r.top, r.left + r.width, r.top + r.height],
};

Future<void> _pageMode(
  MangaOcrServiceImpl service,
  String dataDir,
  List<Map<String, Object?>> records,
  IOSink out,
) async {
  final MangaOcrPageSession session = await service.openPageSession(
    imageDirPath: dataDir,
  );
  final String cacheDir = await service.resolvePageCacheDirPath(
    imageDirPath: dataDir,
  );
  try {
    for (final Map<String, Object?> record in records) {
      final String rel = record['image']! as String;
      final File cached = File(p.join(cacheDir, ocrPageCacheFileName(rel)));
      if (await cached.exists()) await cached.delete();
      final Stopwatch run = Stopwatch()..start();
      await session.ocrPage(rel);
      final int ms = run.elapsedMilliseconds;
      final OcrPageResult? result = await MangaOcrFilePageCache(
        cacheDir: Directory(cacheDir),
        pageNames: <String>[rel],
        pageFiles: <File>[File(p.join(dataDir, rel))],
      ).read('eval', 0);
      if (result == null) throw StateError('$rel 识别后没有逐页缓存');
      out.writeln(
        jsonEncode(<String, Object?>{
          'image': rel,
          'ms': ms,
          'blocks': <Map<String, Object?>>[
            for (final OcrBlock b in result.blocks)
              <String, Object?>{
                ..._rect(b.box),
                'vertical': b.vertical,
                'lines': b.lines,
                'lineBoxes': <List<double>>[
                  for (final OcrRect r in b.lineBoxes ?? const <OcrRect>[])
                    _rect(r)['box']! as List<double>,
                ],
              },
          ],
        }),
      );
      stdout.writeln('$rel ${ms}ms ${result.blocks.length} blocks');
    }
  } finally {
    await session.close();
  }
}

Future<void> _textMode(
  MangaOcrServiceImpl service,
  String dataDir,
  List<Map<String, Object?>> records,
  IOSink out,
  double band,
) async {
  final MangaOcrPageSession session = await service.openPageSession(
    imageDirPath: dataDir,
    textImagesOnly: true,
  );
  final MangaOcrTextImageSession text = session as MangaOcrTextImageSession;
  try {
    for (final Map<String, Object?> record in records) {
      final String rel = record['image']! as String;
      final img.Image? decoded = img.decodeImage(
        await File(p.join(dataDir, rel)).readAsBytes(),
      );
      if (decoded == null) throw FormatException('解不开图片: $rel');
      final int top = (decoded.height * band).round();
      final img.Image crop = img
          .copyCrop(
            decoded,
            x: 0,
            y: top,
            width: decoded.width,
            height: decoded.height - top,
          )
          .convert(numChannels: 4);
      final Uint8List rgba = crop.getBytes(order: img.ChannelOrder.rgba);
      final Stopwatch run = Stopwatch()..start();
      final OcrRecognition r = await text.recognizeTextImage(
        rgba,
        width: crop.width,
        height: crop.height,
      );
      final int ms = run.elapsedMilliseconds;
      final List<String> lines = r.lines ?? <String>[r.text];
      final List<OcrRect> boxes = r.lineBoxes ?? const <OcrRect>[];
      out.writeln(
        jsonEncode(<String, Object?>{
          'image': rel,
          'ms': ms,
          'blocks': <Map<String, Object?>>[
            <String, Object?>{
              'box': <double>[
                0,
                top.toDouble(),
                crop.width.toDouble(),
                decoded.height.toDouble(),
              ],
              'vertical': r.vertical,
              'lines': lines,
              'lineBoxes': <List<double>>[
                for (final OcrRect b in boxes)
                  <double>[
                    b.left,
                    b.top + top,
                    b.left + b.width,
                    b.top + top + b.height,
                  ],
              ],
            },
          ],
        }),
      );
      stdout.writeln('$rel ${ms}ms ${lines.length} lines');
    }
  } finally {
    await session.close();
  }
}
