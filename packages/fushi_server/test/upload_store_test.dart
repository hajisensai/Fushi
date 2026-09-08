import 'dart:convert';
import 'dart:io';

import 'package:fushi_server/src/admin/upload_store.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late LibraryRootConfig lib;
  late UploadStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_upload_');
    lib = LibraryRootConfig(id: 'l', path: p.join(tmp.path, 'lib'));
    store = UploadStore(
      ledgerFile: File(p.join(tmp.path, 'ledger.json')),
      quotaBytes: 1000,
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Stream<List<int>> bytes(String s) => Stream<List<int>>.value(utf8.encode(s));

  test('路径穿越被拒', () {
    expect(() => UploadStore.resolveTarget(lib, '../x.mkv'), throwsA(isA<UploadRejected>()));
    expect(() => UploadStore.resolveTarget(lib, 'a/../../x.mkv'), throwsA(isA<UploadRejected>()));
    expect(() => UploadStore.resolveTarget(lib, '/abs.mkv'), throwsA(isA<UploadRejected>()));
    expect(() => UploadStore.resolveTarget(lib, ''), throwsA(isA<UploadRejected>()));
    expect(UploadStore.resolveTarget(lib, 'Season1/ep01.mkv'), p.normalize(p.join(lib.path, 'Season1', 'ep01.mkv')));
  });

  test('分块追加，收齐后 .part 改名成目标', () async {
    final String target = UploadStore.resolveTarget(lib, 'a/b.txt');
    final ({int received, bool complete}) r1 = await store.putChunk(
      target: target,
      body: bytes('hello '),
      rangeStart: 0,
      total: 11,
      declaredLength: 6,
    );
    expect(r1, (received: 6, complete: false));
    expect(File('$target.part').existsSync(), isTrue);
    expect(File(target).existsSync(), isFalse);
    expect(await store.received(target), 6);

    final ({int received, bool complete}) r2 = await store.putChunk(
      target: target,
      body: bytes('world'),
      rangeStart: 6,
      total: 11,
      declaredLength: 5,
    );
    expect(r2, (received: 11, complete: true));
    expect(File('$target.part').existsSync(), isFalse);
    expect(File(target).readAsStringSync(), 'hello world');
    expect(await store.used(), 11);
  });

  test('偏移不匹配 409（客户端先 GET received 再续传）', () async {
    final String target = UploadStore.resolveTarget(lib, 'c.txt');
    await store.putChunk(target: target, body: bytes('abc'), rangeStart: 0, total: 6, declaredLength: 3);
    expect(
      () => store.putChunk(target: target, body: bytes('xyz'), rangeStart: 1, total: 6, declaredLength: 3),
      throwsA(isA<UploadRejected>().having((UploadRejected e) => e.status, 'status', 409)),
    );
  });

  test('超配额 413，账本跨实例持久', () async {
    final String target = UploadStore.resolveTarget(lib, 'big.bin');
    expect(
      () => store.putChunk(target: target, body: bytes('x'), rangeStart: 0, total: 5000, declaredLength: 5000),
      throwsA(isA<UploadRejected>().having((UploadRejected e) => e.status, 'status', 413)),
    );
    await store.putChunk(target: target, body: bytes('12345'), rangeStart: 0, total: 5, declaredLength: 5);
    final UploadStore again = UploadStore(ledgerFile: store.ledgerFile, quotaBytes: 1000);
    expect(await again.used(), 5);
  });

  test('Content-Range 解析', () {
    expect(parseContentRange('bytes 0-99/1000'), (start: 0, total: 1000));
    expect(parseContentRange('bytes 500-999/*'), (start: 500, total: null));
    expect(parseContentRange('items 0-1/2'), isNull);
    expect(parseContentRange(null), isNull);
  });
}
