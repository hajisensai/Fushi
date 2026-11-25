// TyranoScript DOM 语音：asar 成员读取、签名校验、存储路径解析。全部用自造的小 asar /
// 合成字节，不含任何游戏内容。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi/src/mining/tyrano_dom/tyrano_asar.dart';
import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_voice.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final Uint8List _ogg = Uint8List.fromList(<int>[
  0x4f, 0x67, 0x67, 0x53, 0, 2, 9, 8, 7, 6, 5, 4, //
]);
final Uint8List _m4a = Uint8List.fromList(<int>[
  0, 0, 0, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4d, 0x34, 0x41, 0x20, 1, 2, //
]);
final Uint8List _png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0, //
]);

/// 按 Electron asar 格式写包：成员按顺序紧排在数据区，offset 是十进制字符串。
/// [unpacked] 里的成员只登记在头里（`unpacked: true`），内容写到 `<包>.unpacked/`。
void _writeAsar(
  String path,
  Map<String, Uint8List> members, {
  Map<String, Uint8List> unpacked = const <String, Uint8List>{},
  int padding = 0,
}) {
  final Map<String, Object?> root = <String, Object?>{
    'files': <String, Object?>{},
  };
  final BytesBuilder data = BytesBuilder()
    ..add(List<int>.filled(padding, 0xee));
  void put(String member, Map<String, Object?> node) {
    final List<String> parts = member.split('/');
    Map<String, Object?> dir = root;
    for (final String part in parts.take(parts.length - 1)) {
      final Map<String, Object?> files = dir['files']! as Map<String, Object?>;
      dir =
          files.putIfAbsent(
                part,
                () => <String, Object?>{'files': <String, Object?>{}},
              )
              as Map<String, Object?>;
    }
    (dir['files']! as Map<String, Object?>)[parts.last] = node;
  }

  members.forEach((String member, Uint8List bytes) {
    put(member, <String, Object?>{
      'size': bytes.length,
      'offset': '${data.length}',
    });
    data.add(bytes);
  });
  unpacked.forEach((String member, Uint8List bytes) {
    put(member, <String, Object?>{'size': bytes.length, 'unpacked': true});
    File(p.joinAll(<String>['$path.unpacked', ...member.split('/')]))
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  });
  final List<int> json = utf8.encode(jsonEncode(root));
  final int padded = (json.length + 3) & ~3;
  final ByteData head = ByteData(16)
    ..setUint32(0, 4, Endian.little)
    ..setUint32(4, padded + 8, Endian.little)
    ..setUint32(8, padded + 4, Endian.little)
    ..setUint32(12, json.length, Endian.little);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[
      ...head.buffer.asUint8List(),
      ...json,
      ...List<int>.filled(padded - json.length, 0),
      ...data.takeBytes(),
    ]);
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('tyrano_voice_'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('AsarArchive', () {
    test('按 offset/size 精确读成员（前面有别的成员与填充也不串字节）', () async {
      final String asar = p.join(temp.path, 'app.asar');
      _writeAsar(asar, <String, Uint8List>{
        'index.html': Uint8List.fromList(utf8.encode('<html></html>')),
        'data/sound/vo/a/1.ogg': _ogg,
        'data/sound/vo/b/2.m4a': _m4a,
      }, padding: 7);
      final AsarArchive archive = AsarArchive.openSync(asar)!;
      expect(archive.topLevelEntries, <String>{'index.html', 'data'});
      final AsarMember ogg = archive.member('data/sound/vo/a/1.ogg')!;
      expect(ogg.size, _ogg.length);
      expect(await archive.read(ogg, maxBytes: 1 << 20), _ogg);
      final AsarMember m4a = archive.member(r'data\sound\vo\b\2.m4a')!;
      expect(await archive.read(m4a, maxBytes: 1 << 20), _m4a);
      // 后台 isolate 版解析出同样的结构。
      final AsarArchive? viaIsolate = await AsarArchive.open(asar);
      expect(viaIsolate!.member('data/sound/vo/a/1.ogg')!.offset, ogg.offset);
    });

    test('unpacked 成员读 <包>.unpacked/，大小必须与头一致', () async {
      final String asar = p.join(temp.path, 'app.asar');
      _writeAsar(
        asar,
        <String, Uint8List>{'index.html': Uint8List(3)},
        unpacked: <String, Uint8List>{'data/sound/vo/x.ogg': _ogg},
      );
      final AsarArchive archive = AsarArchive.openSync(asar)!;
      final AsarMember member = archive.member('data/sound/vo/x.ogg')!;
      expect(member.unpacked, isTrue);
      expect(await archive.read(member, maxBytes: 1 << 20), _ogg);
      File(
        p.join('$asar.unpacked', 'data', 'sound', 'vo', 'x.ogg'),
      ).writeAsBytesSync(<int>[1, 2]);
      expect(await archive.read(member, maxBytes: 1 << 20), isNull);
    });

    test('目录 / 不存在 / .. / 越界 / 超上限 都不给成员或字节', () async {
      final String asar = p.join(temp.path, 'app.asar');
      _writeAsar(asar, <String, Uint8List>{'data/sound/v.ogg': _ogg});
      final AsarArchive archive = AsarArchive.openSync(asar)!;
      expect(archive.member('data/sound'), isNull);
      expect(archive.member('data/sound/none.ogg'), isNull);
      expect(archive.member('data/../data/sound/v.ogg'), isNull);
      final AsarMember member = archive.member('data/sound/v.ogg')!;
      expect(await archive.read(member, maxBytes: 4), isNull);
      // 截断归档：头里的 offset+size 超出文件 → 不给成员。
      final List<int> all = File(asar).readAsBytesSync();
      File(asar).writeAsBytesSync(all.sublist(0, all.length - 2));
      expect(AsarArchive.openSync(asar)!.member('data/sound/v.ogg'), isNull);
    });

    test('不是 asar → null', () {
      final File junk = File(p.join(temp.path, 'junk.asar'))
        ..writeAsBytesSync(List<int>.filled(64, 7));
      expect(AsarArchive.openSync(junk.path), isNull);
      expect(AsarArchive.openSync(p.join(temp.path, 'missing.asar')), isNull);
    });
  });

  group('签名', () {
    test('OggS → ogg，ftyp → m4a，其它 → null（不看扩展名）', () {
      expect(sniffTyranoVoiceContainer(_ogg), TyranoVoiceContainer.ogg);
      expect(sniffTyranoVoiceContainer(_m4a), TyranoVoiceContainer.m4a);
      expect(sniffTyranoVoiceContainer(_png), isNull);
      expect(sniffTyranoVoiceContainer(Uint8List(3)), isNull);
    });
  });

  group('resolveTyranoDomVoiceLocation', () {
    const String page =
        'file:///D:/%E6%B8%B8%E6%88%8F/Game/resources/app.asar/index.html';

    test('引擎 parseStorage 结果按页面 URL 落进 app.asar', () {
      final r = resolveTyranoDomVoiceLocation(
        pageUrl: page,
        storagePath: './data/sound/vo/lily/1.ogg',
      );
      expect(r.skip, isNull);
      expect(
        r.location!.filePath,
        r'D:\游戏\Game\resources\app.asar\data\sound\vo\lily\1.ogg',
      );
      expect(r.location!.pageDir, r'D:\游戏\Game\resources\app.asar');
    });

    test('%XX 按浏览器语义解码，?query / #fragment 丢掉', () {
      final r = resolveTyranoDomVoiceLocation(
        pageUrl: page,
        storagePath: './data/sound/vo/%E3%81%82%20b.ogg?v=2#x',
      );
      expect(
        r.location!.filePath,
        r'D:\游戏\Game\resources\app.asar\data\sound\vo\あ b.ogg',
      );
    });

    test('页面目录内的 file: URL / 盘符绝对路径可用；目录外一律拒绝', () {
      expect(
        resolveTyranoDomVoiceLocation(
          pageUrl: page,
          storagePath: r'D:\游戏\Game\resources\app.asar\data\sound\x.ogg',
        ).location,
        isNotNull,
      );
      expect(
        resolveTyranoDomVoiceLocation(
          pageUrl: page,
          storagePath: 'file:///C:/Windows/win.ini',
        ).skip,
        TyranoDomVoiceSkip.outsideGame,
      );
      expect(
        resolveTyranoDomVoiceLocation(
          pageUrl: page,
          storagePath: r'C:\Users\x\secret.ogg',
        ).skip,
        TyranoDomVoiceSkip.outsideGame,
      );
      expect(
        resolveTyranoDomVoiceLocation(
          pageUrl: page,
          storagePath: '../../../evil.ogg',
        ).skip,
        TyranoDomVoiceSkip.outsideGame,
      );
    });

    test('http / base64 / 非 file 页面不处理', () {
      expect(
        resolveTyranoDomVoiceLocation(
          pageUrl: page,
          storagePath: 'https://example.invalid/v.ogg',
        ).skip,
        TyranoDomVoiceSkip.remote,
      );
      expect(
        resolveTyranoDomVoiceLocation(
          pageUrl: page,
          storagePath: './data/sound/v.txt',
          base64: true,
        ).skip,
        TyranoDomVoiceSkip.base64,
      );
      expect(
        resolveTyranoDomVoiceLocation(
          pageUrl: 'http://127.0.0.1/index.html',
          storagePath: './data/sound/v.ogg',
        ).skip,
        TyranoDomVoiceSkip.outsideGame,
      );
    });
  });

  // 解析按 Windows 路径语义（galgame 只做 Windows 端），读盘用例只在 Windows 上跑。
  group('TyranoDomVoiceReader', skip: !Platform.isWindows, () {
    String pageUrlFor(String indexPath) => Uri.file(indexPath).toString();

    test('Electron：从 app.asar 取成员原件，字节与写入一致', () async {
      final String asar = p.join(temp.path, 'resources', 'app.asar');
      _writeAsar(asar, <String, Uint8List>{
        'index.html': Uint8List(4),
        'data/sound/vo/a/1.ogg': _ogg,
        'data/sound/vo/b/1.m4a': _m4a,
        'data/sound/vo/c/1.ogg': _png,
      });
      final TyranoDomVoiceReader reader = TyranoDomVoiceReader();
      Future<({TyranoDomVoiceBytes? voice, TyranoDomVoiceSkip? skip})> read(
        String storage,
      ) => reader.read(
        resolveTyranoDomVoiceLocation(
          pageUrl: pageUrlFor(p.join(asar, 'index.html')),
          storagePath: storage,
        ).location!,
      );

      final ogg = await read('./data/sound/vo/a/1.ogg');
      expect(ogg.voice!.bytes, _ogg);
      expect(ogg.voice!.container, TyranoVoiceContainer.ogg);
      expect(ogg.voice!.asarPath, asar);
      expect(ogg.voice!.asarMember, 'data/sound/vo/a/1.ogg');
      final m4a = await read('./data/sound/vo/b/1.m4a');
      expect(m4a.voice!.container, TyranoVoiceContainer.m4a);
      expect(
        (await read('./data/sound/vo/c/1.ogg')).skip,
        TyranoDomVoiceSkip.badSignature,
      );
      expect(
        (await read('./data/sound/vo/none.ogg')).skip,
        TyranoDomVoiceSkip.notFound,
      );
    });

    test('NW.js / 未打包目录：普通文件；名字以 .asar 结尾的目录不当归档', () async {
      final String app = p.join(temp.path, 'odd.asar');
      File(p.join(app, 'data', 'sound', 'v.ogg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(_ogg);
      final TyranoDomVoiceReader reader = TyranoDomVoiceReader();
      final r = await reader.read(
        resolveTyranoDomVoiceLocation(
          pageUrl: pageUrlFor(p.join(app, 'index.html')),
          storagePath: './data/sound/v.ogg',
        ).location!,
      );
      expect(r.voice!.bytes, _ogg);
      expect(r.voice!.asarPath, isNull);
    });
  });

  group('dump 文件名片段', () {
    test('取 data/sound/ 之后，/ 换 -，扩展名按签名', () {
      expect(
        tyranoVoiceDumpBasename(
          r'D:\g\resources\app.asar\data\sound\vo\lily\1.ogg',
          TyranoVoiceContainer.ogg,
        ),
        'vo-lily-1.ogg',
      );
      expect(
        tyranoVoiceDumpBasename(
          r'D:\g\app\data\sound\v_01.ogg',
          TyranoVoiceContainer.m4a,
        ),
        'v_01.m4a',
      );
      expect(
        tyranoVoiceDumpBasename(r'D:\g\other\x.ogg', TyranoVoiceContainer.ogg),
        'other-x.ogg',
      );
    });
  });

  group('parseTyranoDomVoicePayload', () {
    test('解析脚本载荷；缺字段 / 不是语音返回 null', () {
      final TyranoDomVoiceEvent event =
          parseTyranoDomVoicePayload(<String, Object?>{
            'v': 1,
            'k': 'voice',
            'doc': 'd1',
            'ln': 3,
            'buf': '1',
            'path': './data/sound/vo/lily/1.ogg',
            'b64': false,
          })!;
      expect(event.documentId, 'd1');
      expect(event.lineSeq, 3);
      expect(event.buffer, '1');
      expect(event.storagePath, './data/sound/vo/lily/1.ogg');
      expect(event.withPageUrl('file:///x').pageUrl, 'file:///x');
      expect(
        parseTyranoDomVoicePayload(<String, Object?>{'k': 'voice', 'ln': 1}),
        isNull,
      );
      expect(
        parseTyranoDomVoicePayload(<String, Object?>{
          'k': 'other',
          'doc': 'd',
          'ln': 1,
          'path': 'x',
        }),
        isNull,
      );
    });
  });
}
