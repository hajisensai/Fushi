// 真并发压测，各平台都跑。Windows 上两个 rename 在同一瞬间替换同一个目标时
// `MoveFileEx` 会让其中一个以「拒绝访问」失败，所以那里替换目标要排队
// （atomic_text_file.dart 的 `_replaceTarget`）；POSIX 的 rename 本来就能并发。
// 两边的结局一样：全部写者成功，目标是其中一份完整内容。Windows 这一侧自己的
// 断言（锁文件在哪、留不留东西）在 atomic_text_file_concurrent_windows_test.dart。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/utils/misc/atomic_text_file.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 目录里残留的临时文件（任何以 `.tmp` 结尾的）。
List<String> _leftoverTemporaries(Directory dir) => <String>[
  for (final FileSystemEntity entry in dir.listSync(recursive: true))
    if (entry is File && entry.path.endsWith('.tmp')) p.basename(entry.path),
];

/// BUG-4801：同一个目标的并发写者各用各的临时文件，后 rename 的覆盖先 rename
/// 的，谁也不会把别人写到一半的文件带走。
void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('atomic_text_file_mt_');
  });

  tearDown(() {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  });

  test('并发写同一个目标：都成功，目标是其中一份完整内容，不留临时文件', () async {
    final File target = File(p.join(temporary.path, 'page.json'));
    // 内容够大，让各次写入真正交叠；固定名下它们写的是同一个临时文件，先
    // rename 的把文件带走，后 rename 的找不到源。
    final List<String> contents = <String>[
      for (int i = 0; i < 12; i++) jsonEncode(List<int>.filled(200000, i)),
    ];
    await Future.wait(<Future<void>>[
      for (final String content in contents)
        writeTextFileAtomically(target, content),
    ]);
    expect(contents, contains(target.readAsStringSync()));
    expect(_leftoverTemporaries(temporary), isEmpty);
  });

  test('四个 isolate 并发写同一个目标：都成功，目标是完整内容', () async {
    final String targetPath = p.join(temporary.path, 'page.json');
    Future<void> writer(int seed) => Isolate.run<void>(() async {
      for (int i = 0; i < 40; i++) {
        await writeTextFileAtomically(
          File(targetPath),
          jsonEncode(List<int>.filled(20000, seed)),
        );
      }
    });

    await Future.wait(<Future<void>>[
      for (int seed = 1; seed <= 4; seed++) writer(seed),
    ]);
    final Object? decoded = jsonDecode(File(targetPath).readAsStringSync());
    expect(decoded, isA<List<Object?>>());
    expect((decoded! as List<Object?>).length, 20000);
    expect(_leftoverTemporaries(temporary), isEmpty);
  });

  // 整卷任务与页级会话、取消后还在收尾的旧任务与新任务，都会各拿一个
  // MangaOcrFilePageCache 写同一页。
  test('逐页缓存：两个写者并发写同一页，都成功且读回的是完整结果', () async {
    final File page = File(p.join(temporary.path, 'p1.png'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final Directory cacheDir = Directory(p.join(temporary.path, 'cache'));
    MangaOcrFilePageCache cache() => MangaOcrFilePageCache(
      cacheDir: cacheDir,
      pageNames: const <String>['p1.png'],
      pageFiles: <File>[page],
    );
    OcrPageResult result(int width) => OcrPageResult(
      pageIndex: 0,
      imageWidth: width,
      imageHeight: 80,
      blocks: <OcrBlock>[
        for (int i = 0; i < 400; i++)
          OcrBlock(
            box: OcrRect(left: 0, top: i * 1.0, right: 10, bottom: i + 1.0),
            vertical: true,
            lines: <String>['line $i of writer $width'],
          ),
      ],
    );

    final MangaOcrFilePageCache oldJob = cache();
    final MangaOcrFilePageCache newJob = cache();
    await Future.wait(<Future<void>>[
      for (int i = 0; i < 6; i++) ...<Future<void>>[
        oldJob.write('manga_ocr', result(40)),
        newJob.write('manga_ocr', result(50)),
      ],
    ]);

    final OcrPageResult? read = await cache().read('manga_ocr', 0);
    expect(read, isNotNull, reason: '半截 JSON 会被当成缓存未命中');
    expect(read!.blocks, hasLength(400));
    expect(<int>[40, 50], contains(read.imageWidth));
    expect(_leftoverTemporaries(temporary), isEmpty);
  });

  // Windows 上读者把目标打开着的那一刻，写者的 rename 会「拒绝访问」；读者走
  // readAtomicallyWrittenTextFile 之后与替换互斥。POSIX 上本来就不冲突。
  test('一个读者循环读、一个写者循环写同一个目标：写入全部成功，读到的都是完整内容', () async {
    final File target = File(p.join(temporary.path, 'page.json'));
    await writeTextFileAtomically(
      target,
      jsonEncode(List<int>.filled(20000, 0)),
    );
    bool writing = true;
    int reads = 0;
    Future<void> reader() async {
      while (writing) {
        final Object? decoded = jsonDecode(
          await readAtomicallyWrittenTextFile(target),
        );
        expect((decoded! as List<Object?>).length, 20000);
        reads += 1;
      }
    }

    final Future<void> reading = reader();
    try {
      for (int i = 1; i <= 300; i++) {
        await writeTextFileAtomically(
          target,
          jsonEncode(List<int>.filled(20000, i)),
        );
      }
    } finally {
      writing = false;
    }
    await reading;
    expect(reads, greaterThan(0));
    expect(_leftoverTemporaries(temporary), isEmpty);
  });

  test('别的 isolate 里的读者循环读，这边循环写同一个目标：写入全部成功', () async {
    final String targetPath = p.join(temporary.path, 'page.json');
    final String stopPath = p.join(temporary.path, 'stop');
    await writeTextFileAtomically(
      File(targetPath),
      jsonEncode(List<int>.filled(20000, 0)),
    );
    Future<int> reader() => Isolate.run<int>(() async {
      int reads = 0;
      while (!File(stopPath).existsSync()) {
        final Object? decoded = jsonDecode(
          await readAtomicallyWrittenTextFile(File(targetPath)),
        );
        if ((decoded! as List<Object?>).length != 20000) {
          throw StateError('torn read');
        }
        reads += 1;
      }
      return reads;
    });

    final List<Future<int>> readers = <Future<int>>[reader(), reader()];
    try {
      for (int i = 1; i <= 300; i++) {
        await writeTextFileAtomically(
          File(targetPath),
          jsonEncode(List<int>.filled(20000, i)),
        );
      }
    } finally {
      File(stopPath).writeAsStringSync('');
    }
    for (final int reads in await Future.wait(readers)) {
      expect(reads, greaterThan(0));
    }
    expect(_leftoverTemporaries(temporary), isEmpty);
  });

  // 整卷任务读某页缓存做续传校验的同一刻，页级会话写完同一页。
  test('逐页缓存：一边循环读、一边循环写同一页，写入全部成功', () async {
    final File page = File(p.join(temporary.path, 'p1.png'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final Directory cacheDir = Directory(p.join(temporary.path, 'cache'));
    MangaOcrFilePageCache cache() => MangaOcrFilePageCache(
      cacheDir: cacheDir,
      pageNames: const <String>['p1.png'],
      pageFiles: <File>[page],
    );
    OcrPageResult result(int width) => OcrPageResult(
      pageIndex: 0,
      imageWidth: width,
      imageHeight: 80,
      blocks: <OcrBlock>[
        for (int i = 0; i < 400; i++)
          OcrBlock(
            box: OcrRect(left: 0, top: i * 1.0, right: 10, bottom: i + 1.0),
            vertical: true,
            lines: <String>['line $i of writer $width'],
          ),
      ],
    );

    final MangaOcrFilePageCache volumeJob = cache();
    final MangaOcrFilePageCache pageSession = cache();
    await pageSession.write('manga_ocr', result(1));
    bool writing = true;
    int hits = 0;
    Future<void> reader() async {
      while (writing) {
        final OcrPageResult? read = await volumeJob.read('manga_ocr', 0);
        expect(read, isNotNull);
        expect(read!.blocks, hasLength(400));
        hits += 1;
      }
    }

    final Future<void> reading = reader();
    try {
      for (int i = 2; i <= 200; i++) {
        await pageSession.write('manga_ocr', result(i));
      }
    } finally {
      writing = false;
    }
    await reading;
    expect(hits, greaterThan(0));
    expect((await cache().read('manga_ocr', 0))!.imageWidth, 200);
    expect(_leftoverTemporaries(temporary), isEmpty);
  });
}
