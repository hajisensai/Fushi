// BUG-5311：曲库唱片每次冷启动都要等一会才出来——按内容判扫图与量盘面几何的结果
// 只在进程里。这里模拟「退出再启动」（清空进程内缓存、从落盘文件重读），断言文件
// 没变就不再解码，文件变了才重新解码。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_disc_art.dart';
import 'package:fushi/src/media/music/music_disc_art_store.dart';
import 'package:path/path.dart' as p;

/// [size] 见方的样本：[disc] 为真时是白底上平放的一张光盘，否则是一张渐变图。
MusicDiscFaceSample _sample({required bool disc, int size = 96}) {
  final Uint8List px = Uint8List(size * size * 4);
  final double c = (size - 1) / 2;
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final double r =
          math.sqrt((x - c) * (x - c) + (y - c) * (y - c)) / (size / 2);
      final List<int> rgb = !disc
          ? <int>[x * 2 % 256, y * 2 % 256, 90]
          : r > 0.99 || r < 0.08
          ? <int>[250, 250, 250]
          : r < 0.2
          ? <int>[200, 200, 205]
          : <int>[(x * 3) % 200, 60, (y * 5) % 220];
      final int i = (y * size + x) * 4;
      px[i] = rgb[0];
      px[i + 1] = rgb[1];
      px[i + 2] = rgb[2];
      px[i + 3] = 255;
    }
  }
  return MusicDiscFaceSample(
    sourceWidth: 1000,
    sourceHeight: 1000,
    size: size,
    rgba: px,
  );
}

void main() {
  late Directory tmp;
  late File cacheFile;
  final MusicDiscArtStore store = MusicDiscArtStore.instance;
  final MusicDiscArtIndex index = MusicDiscArtIndex.instance;
  final MusicDiscFaceGeometryCache geometry =
      MusicDiscFaceGeometryCache.instance;
  final Future<File?> Function() realResolver = store.fileResolver;
  final MusicDiscFaceSampler realIndexSampler = index.sampler;
  final MusicDiscFaceSampler realGeometrySampler = geometry.sampler;

  /// 模拟冷启动：进程内缓存全清，落盘文件留着。
  Future<void> restart() async {
    await store.debugReset();
    index.invalidate();
    geometry.invalidate();
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('fushi_disc_art_store_');
    cacheFile = File(p.join(tmp.path, 'cache', 'disc_art_cache.json'));
    store.fileResolver = () async => cacheFile;
    await restart();
  });

  tearDown(() async {
    await store.debugReset();
    store.fileResolver = realResolver;
    index
      ..sampler = realIndexSampler
      ..invalidate();
    geometry
      ..sampler = realGeometrySampler
      ..invalidate();
    tmp.deleteSync(recursive: true);
  });

  test('按内容认出的盘面图：冷启动文件没变不再解码，文件变了才重判', () async {
    final Directory album = Directory(p.join(tmp.path, 'Album'))..createSync();
    Directory(p.join(album.path, 'Scans')).createSync();
    for (final String n in <String>['01', '02', '03']) {
      File(p.join(album.path, 'Scans', '$n.webp')).writeAsBytesSync(<int>[0]);
    }
    final Map<String, List<String>> tracks = <String, List<String>>{
      'a': <String>[p.join(album.path, '01.flac')],
    };
    final List<String> sampled = <String>[];
    index.sampler = (String path) async {
      sampled.add(p.basename(path));
      return _sample(disc: p.basenameWithoutExtension(path) == '02');
    };
    final String disc = p.join(album.path, 'Scans', '02.webp');

    expect(await index.resolve(tracks), <String, String>{'a': disc});
    expect(sampled, <String>['01.webp', '02.webp']);
    await store.flush();
    expect(cacheFile.existsSync(), isTrue);

    // 冷启动：结论从落盘读回，一张都不解码。
    await restart();
    sampled.clear();
    expect(await index.resolve(tracks), <String, String>{'a': disc});
    expect(sampled, isEmpty);

    // 01 被换成另一张（大小变了）：只重判它，02 仍用落盘结论。
    File(
      p.join(album.path, 'Scans', '01.webp'),
    ).writeAsBytesSync(<int>[0, 1, 2]);
    await store.flush();
    await restart();
    sampled.clear();
    expect(await index.resolve(tracks), <String, String>{'a': disc});
    expect(sampled, <String>['01.webp']);
  });

  test('盘面几何：冷启动文件没变直接认领（peek 首帧可用），文件变了重新量', () async {
    final File image = File(p.join(tmp.path, 'disc.png'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    int calls = 0;
    geometry.sampler = (String path) async {
      calls++;
      return _sample(disc: true, size: kMusicDiscGeometrySampleSize);
    };

    final MusicDiscFaceGeometry first = await geometry.load(image.path);
    expect(calls, 1);
    await store.flush();

    await restart();
    expect(geometry.peek(image.path), isNull);
    await geometry.preload(<String>{image.path});
    expect(geometry.peek(image.path), first);
    expect(await geometry.load(image.path), first);
    expect(calls, 1);

    // 没先 preload 直接 load 也走落盘结果。
    await restart();
    expect(await geometry.load(image.path), first);
    expect(calls, 1);

    // 扫图被替换：落盘几何作废，重新量。
    image.writeAsBytesSync(<int>[1, 2, 3, 4, 5]);
    await restart();
    await geometry.preload(<String>{image.path});
    expect(geometry.peek(image.path), isNull);
    await geometry.load(image.path);
    expect(calls, 2);
  });

  test('新列外层专辑目录时，不删嵌套在里面的另一张专辑（已知根）的落盘结论', () async {
    final Directory outer = Directory(p.join(tmp.path, 'Outer'))..createSync();
    final Directory inner = Directory(p.join(outer.path, 'Live'))..createSync();
    Directory(p.join(inner.path, 'Scans')).createSync();
    File(p.join(inner.path, 'Scans', '01.webp')).writeAsBytesSync(<int>[0]);
    final String innerDisc = p.join(inner.path, 'Scans', '01.webp');
    final List<String> sampled = <String>[];
    index.sampler = (String path) async {
      sampled.add(path);
      return _sample(disc: true);
    };
    final Map<String, List<String>> innerOnly = <String, List<String>>{
      'live': <String>[p.join(inner.path, '01.flac')],
    };

    expect(await index.resolve(innerOnly), <String, String>{'live': innerDisc});
    expect(sampled, <String>[innerDisc]);

    // 同一进程里又出现外层专辑（只重列 Outer，Live 是已知根）：Live 的结论不归
    // Outer 的候选集判，不能被当成「已不再是候选」删掉。
    expect(
      await index.resolve(<String, List<String>>{
        ...innerOnly,
        'outer': <String>[p.join(outer.path, '01.flac')],
      }),
      <String, String>{'live': innerDisc},
    );
    await store.flush();

    await restart();
    sampled.clear();
    expect(await index.resolve(innerOnly), <String, String>{'live': innerDisc});
    expect(sampled, isEmpty);
  });

  test('resolve 发布前认领落盘几何：卡片拿到映射时几何已就绪', () async {
    final Directory album = Directory(p.join(tmp.path, 'B'))..createSync();
    final File disc = File(p.join(album.path, 'disc.jpg'))
      ..writeAsBytesSync(<int>[9]);
    geometry.sampler = (String path) async =>
        _sample(disc: true, size: kMusicDiscGeometrySampleSize);
    final MusicDiscFaceGeometry measured = await geometry.load(disc.path);
    await store.flush();

    await restart();
    final Map<String, String> found = await index.resolve(
      <String, List<String>>{
        'b': <String>[p.join(album.path, '01.flac')],
      },
    );
    expect(found, <String, String>{'b': disc.path});
    expect(geometry.peek(disc.path), measured);
  });

  test('缓存文件损坏 / 版本不对：当空缓存，照常识别并覆盖', () async {
    cacheFile.parent.createSync(recursive: true);
    cacheFile.writeAsStringSync('{not json');
    final File image = File(p.join(tmp.path, 'x.png'))
      ..writeAsBytesSync(<int>[1]);
    int calls = 0;
    geometry.sampler = (String path) async {
      calls++;
      return _sample(disc: true, size: kMusicDiscGeometrySampleSize);
    };
    await geometry.load(image.path);
    expect(calls, 1);
    await store.flush();
    expect(cacheFile.readAsStringSync(), contains('"v":1'));

    cacheFile.writeAsStringSync('{"v":0,"faces":{},"geometry":{}}');
    await restart();
    await geometry.load(image.path);
    expect(calls, 2);
  });
}
