// SrsMediaStore 的内容寻址存储：不逐文件 fsync 之后靠「同名必核对内容」自愈，以及并发存
// 同一内容只有一个写入者（从 Anki 迁移时并发预存，集合里常有多个文件名同一内容）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('srs_media_store_'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放。
    }
  });

  Uint8List bytes(int seed, int n) => Uint8List.fromList(
    List<int>.generate(n, (int i) => (i * 31 + seed) & 0xff),
  );

  test('同名文件内容不对（断电留下的坏文件，长度相同）：再存同一内容时重写修好', () async {
    final SrsMediaStore store = SrsMediaStore(Directory(p.join(tmp.path, 'm')));
    final Uint8List data = bytes(7, 4096);
    final String name = await store.store('a.png', data);
    final File file = File(p.join(store.root.path, name));
    expect(file.readAsBytesSync(), data);

    file.writeAsBytesSync(Uint8List(data.length)); // 名字对、长度对、内容全零
    expect(await store.store('again.png', data), name);
    expect(file.readAsBytesSync(), data);
    expect(
      store.root.listSync().where(
        (FileSystemEntity e) => e.path.endsWith('.tmp'),
      ),
      isEmpty,
    );
  });

  test('同名同内容：不重写（修改时刻不变）', () async {
    final SrsMediaStore store = SrsMediaStore(Directory(p.join(tmp.path, 'm')));
    final Uint8List data = bytes(3, 2048);
    final String name = await store.store('a.mp3', data);
    final File file = File(p.join(store.root.path, name));
    final DateTime before = file.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await store.store('b.mp3', data), name);
    expect(file.lastModifiedSync(), before);
  });

  test('不同名字同一内容并发存：不撞共享冲突，只落一个文件', () async {
    final SrsMediaStore store = SrsMediaStore(Directory(p.join(tmp.path, 'm')));
    final Uint8List data = bytes(11, 64 * 1024);
    final List<String> names = await Future.wait(<Future<String>>[
      for (int i = 0; i < 16; i++) store.store('copy$i.jpg', data),
    ]);
    expect(names.toSet(), hasLength(1));
    final List<FileSystemEntity> files = store.root.listSync();
    expect(files, hasLength(1));
    expect((files.single as File).readAsBytesSync(), data);
  });

  test('媒体目录在实例建好之后被删（恢复备份替换整个目录）：照样能存', () async {
    final SrsMediaStore store = SrsMediaStore(Directory(p.join(tmp.path, 'm')));
    await store.store('a.png', bytes(1, 100));
    store.root.deleteSync(recursive: true);
    final String name = await store.store('b.png', bytes(2, 100));
    expect(File(p.join(store.root.path, name)).existsSync(), isTrue);
  });

  // 原生 Fushi 卡面能否画全一张图（引擎据此决定原生 / 整面 WebView）：Flutter 解码器对
  // 动图 AVIF 只出静态主图（实测 frameCount == 1），用户「怎么纯图片了」就是这张卡。
  test('nativeImageDisplayable：动图 AVIF 否，静态 AVIF / 其它格式 / 缺文件 是', () async {
    final SrsMediaStore store = SrsMediaStore(Directory(p.join(tmp.path, 'm')));
    store.root.createSync(recursive: true);
    List<int> ascii(String s) => s.codeUnits;
    // 用户卡上那张动图的真实文件头（ffmpeg 出：主品牌 avis）。
    final List<int> animated = <int>[
      0,
      0,
      0,
      0x2c,
      ...ascii('ftypavis'),
      0,
      0,
      0,
      0,
      ...ascii('avisavifmsf1iso8mif1miafMA1B'),
      0,
      0,
      0,
      0xf9,
      ...ascii('meta'),
    ];
    final List<int> still = <int>[
      0,
      0,
      0,
      0x1c,
      ...ascii('ftypavif'),
      0,
      0,
      0,
      0,
      ...ascii('avifmif1miaf'),
      0,
      0,
      0,
      0x20,
      ...ascii('meta'),
    ];
    File(p.join(store.root.path, 'anim.avif')).writeAsBytesSync(animated);
    File(p.join(store.root.path, 'still.avif')).writeAsBytesSync(still);
    expect(await store.nativeImageDisplayable('anim.avif'), isFalse);
    expect(await store.nativeImageDisplayable('still.avif'), isTrue);
    expect(await store.nativeImageDisplayable('a.webp'), isTrue);
    expect(await store.nativeImageDisplayable('missing.avif'), isTrue);
    expect(await store.nativeImageDisplayable('../x.avif'), isTrue);
  });
}
