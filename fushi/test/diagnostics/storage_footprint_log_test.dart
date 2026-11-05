// BUG-4075：App 数据根的存储分项（目录大小 / 大文件）测量与日志正文。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/diagnostics/storage_footprint_log.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('footprint_'));
  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 上偶发占用，留给系统清理。
    }
  });

  void sized(String rel, int bytes) {
    final File f = File('${root.path}/$rel')..createSync(recursive: true);
    f.openSync(mode: FileMode.write)
      ..truncateSync(bytes)
      ..closeSync();
  }

  test('按目录汇总、只列门槛以上的前两层目录与大文件，按大小降序', () {
    sized('files/srs/srs.db', 160 << 20);
    sized('files/srs/srs.db-wal', 120 << 20);
    sized('files/srs/media/a.jpg', 10 << 20);
    sized('app_flutter/dicts/d1/deep/x.bin', 60 << 20);
    sized('cache/tiny.txt', 3);

    final StorageFootprint f = measureStorageFootprint(root);
    expect(f.fileCount, 5);
    expect(f.totalBytes, (160 + 120 + 10 + 60 << 20) + 3);
    expect(f.dirs, <(String, int)>[
      ('files', 290 << 20),
      ('files/srs', 290 << 20),
      ('app_flutter', 60 << 20),
      ('app_flutter/dicts', 60 << 20),
    ]);
    expect(f.bigFiles, <(String, int)>[
      ('files/srs/srs.db', 160 << 20),
      ('files/srs/srs.db-wal', 120 << 20),
    ]);

    final String text = f.describe('android-data');
    expect(text, startsWith('root=android-data total=350MB files=5'));
    expect(text, contains('\n  files/srs 290MB'));
    expect(text, contains('\n  files/srs/srs.db-wal 120MB'));
    expect(text, isNot(contains('cache')));
    expect(text, isNot(contains(root.path)));
  });

  test('大文件只留前 kStorageFootprintBigFileLimit 条', () {
    for (int i = 0; i < kStorageFootprintBigFileLimit + 3; i++) {
      sized('m/f$i.bin', (100 + i) << 20);
    }
    final StorageFootprint f = measureStorageFootprint(root);
    expect(f.bigFiles, hasLength(kStorageFootprintBigFileLimit));
    expect(f.bigFiles.first.$1, 'm/f${kStorageFootprintBigFileLimit + 2}.bin');
  });

  test('空目录只报总量', () {
    expect(
      measureStorageFootprint(root).describe('support'),
      'root=support total=0B files=0',
    );
  });

  test('字节格式', () {
    expect(formatFootprintBytes(7), '7B');
    expect(formatFootprintBytes(12 << 10), '12KB');
    expect(formatFootprintBytes(340 << 20), '340MB');
    expect(formatFootprintBytes((156 << 30) ~/ 10), '15.6GB');
  });
}
