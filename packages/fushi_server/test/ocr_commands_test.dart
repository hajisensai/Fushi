/// `ocr manga` / `ocr models` / `manga panels` / `manga panel-model` 的参数与退出码契约。
///
/// 测试机没有 OCR / 分镜模型（也不保证有 onnxruntime），所以真推理不在这里跑：
/// 只钉参数解析、合并纯逻辑、`--json` 形状，以及「缺书 66 / 用法 64 / 缺模型或
/// 运行时 69」这些在推理之前就该判出来的路径。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_server/src/commands/import_commands.dart';
import 'package:fushi_server/src/commands/ocr_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'command_harness.dart';

MokuroImage _page(String url, {String text = '', double width = 100}) => MokuroImage(
  url: url,
  size: MokuroSize(width, 200),
  blocks: <MokuroBlock>[
    if (text.isNotEmpty)
      MokuroBlock(
        rectangle: MokuroRect.fromLTRB(0, 0, 10, 10),
        isVertical: true,
        fontSize: 10,
        zIndex: 0,
        lines: <String>[text],
      ),
  ],
);

void main() {
  group('parsePageSelection', () {
    test('1 起闭区间、逗号分隔、去重升序', () {
      expect(parsePageSelection('1-3,5', 10), <int>[0, 1, 2, 4]);
      expect(parsePageSelection('5,1-2, 2', 10), <int>[0, 1, 4]);
      expect(parsePageSelection('10', 10), <int>[9]);
    });

    test('越界 / 倒序 / 非数字 / 空选择抛 FormatException', () {
      for (final String bad in <String>['0', '11', '3-1', 'a', '1-2-3', ',', '']) {
        expect(() => parsePageSelection(bad, 10), throwsFormatException, reason: bad);
      }
    });
  });

  test('mergeMangaOcrPages 只替换对得上的页，其余原样、保留原 url 与元数据', () {
    final MokuroPayload existing = MokuroPayload(
      images: <MokuroImage>[
        _page('images/p001.jpg'),
        _page('images/p002.jpg', text: '旧'),
      ],
      ocr: const MangaOcrMetadata(engine: 'x', engineSignature: 'sig', schemaVersion: 1),
    );
    final MokuroPayload fresh = MokuroPayload(
      images: <MokuroImage>[
        _page('images\\p002.jpg', text: '新', width: 300),
        _page('images/p999.jpg', text: '?'),
      ],
    );
    final ({MokuroPayload payload, int merged}) r = mergeMangaOcrPages(existing, fresh);
    expect(r.merged, 1);
    expect(r.payload.ocr?.engineSignature, 'sig');
    expect(r.payload.images.map((MokuroImage i) => i.url), <String>['images/p001.jpg', 'images/p002.jpg']);
    expect(r.payload.images[0].blocks, isEmpty);
    expect(r.payload.images[1].blocks.single.lines, <String>['新']);
    expect(r.payload.images[1].size.width, 300);
  });

  group('命令', () {
    late CommandHarness h;
    late OcrCommands module;

    setUp(() async {
      h = await CommandHarness.create();
      module = OcrCommands(io: h.io);
    });

    tearDown(() => h.dispose());

    /// 先经 import 命令入库一卷漫画 + 一本书，返回 (漫画 key, 书 key)。
    Future<(String, String)> seed() async {
      final ImportCommands importer = ImportCommands(io: h.io);
      final String vol = p.join(h.tmp.path, 'Vol1');
      writeTestMokuro(vol, 'Vol1');
      final String epub = p.join(h.tmp.path, 'a.epub');
      writeTestEpub(epub, 'Book');
      expect(await h.run(importer, <String>['import', 'auto', vol, epub]), 0, reason: '${h.err}');
      final FushiDatabase db = h.openDb();
      try {
        final List<EpubBookRow> rows = await db.getAllEpubBooks();
        String keyOf(String format) => rows.firstWhere((EpubBookRow r) => r.format == format).bookKey;
        return (keyOf('manga'), keyOf('epub'));
      } finally {
        await db.close();
      }
    }

    test('ocr manga：缺书 66 / 不是漫画 1 / 页号越界 64 / 缺模型或运行时 69', () async {
      final (String manga, String book) = await seed();
      expect(await h.run(module, <String>['ocr', 'manga', 'no-such-book']), 66);
      expect(await h.run(module, <String>['ocr', 'manga', book]), 1);
      expect(h.err.toString(), contains('不是漫画'));
      expect(await h.run(module, <String>['ocr', 'manga', manga, '--pages', '2']), 64);
      expect(await h.run(module, <String>['ocr', 'manga', manga, '--model', 'nope']), 64);
      // 测试机没有下载 OCR 模型：推理前判 69，并提示怎么补。
      expect(await h.run(module, <String>['ocr', 'manga', manga, '--pages', '1']), 69);
      expect(h.err.toString(), anyOf(contains('ocr models pull'), contains('onnxruntime')));
    });

    test('ocr manga 用法错误 → 64', () async {
      expect(await h.run(module, <String>['ocr']), 64);
      expect(await h.run(module, <String>['ocr', 'manga']), 64);
      expect(await h.run(module, <String>['ocr', 'manga', 'a', 'b']), 64);
    });

    test('ocr models ls --json 形状', () async {
      expect(await h.run(module, <String>['ocr', 'models', '--json']), 0, reason: '${h.err}');
      final Map<String, Object?> json = h.json();
      expect(json['runtimeAvailable'], isA<bool>());
      final List<Map<Object?, Object?>> models = (json['models']! as List<Object?>).cast<Map<Object?, Object?>>();
      final Map<Object?, Object?> classic = models.firstWhere((Map<Object?, Object?> m) => m['key'] == 'manga_ocr');
      expect(classic['ready'], isFalse);
      expect(classic['totalBytes'], greaterThan(0));
      expect(classic.keys, containsAll(<String>['name', 'obtainedBytes', 'diskBytes', 'acceleratorMissingBytes']));
    });

    test('ocr models 用法：rm 必须点名、未知动作 / 未知模型 → 64；rm 删不存在的模型释放 0', () async {
      expect(await h.run(module, <String>['ocr', 'models', 'rm']), 64);
      expect(await h.run(module, <String>['ocr', 'models', 'frobnicate']), 64);
      expect(await h.run(module, <String>['ocr', 'models', 'pull', '--model', 'nope']), 64);
      expect(await h.run(module, <String>['ocr', 'models', 'rm', '--model', 'manga_ocr', '--json']), 0);
      expect(h.json(), <String, Object?>{'model': 'manga_ocr', 'freedBytes': 0});
    });

    test('manga panels：缺图 66 / 缺模型 69 / 缺参数 64', () async {
      expect(await h.run(module, <String>['manga', 'panels']), 64);
      expect(await h.run(module, <String>['manga', 'panels', p.join(h.tmp.path, 'nope.png')]), 66);
      final File img = File(p.join(h.tmp.path, 'page.png'))..writeAsBytesSync(<int>[0]);
      expect(await h.run(module, <String>['manga', 'panels', img.path]), 69);
      expect(h.err.toString(), contains('panel-model pull'));
    });

    test('manga panel-model status --json：未下载时 ready=false、退出 0', () async {
      expect(await h.run(module, <String>['manga', 'panel-model', '--json']), 0);
      final Map<String, Object?> json = h.json();
      expect(json['ready'], isFalse);
      expect(json['bytes'], 0);
      expect(
        json['path'],
        endsWith(p.join('support', 'manga_panel_detector', 'manga_panel_detector_yolo26n_fp32.onnx')),
      );
      expect(await h.run(module, <String>['manga', 'panel-model', 'zap']), 64);
    });
  });
}
