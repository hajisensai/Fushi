// BUG-3704：封面 / 海报回退链在 build 里同步 `existsSync`，路径落在网络盘（rclone /
// SMB 挂载）上时冷目录一次 stat 要数秒，UI isolate 与同 isolate 的互联 host 一起
// 冻结。AsyncFileExistenceCache 是这些 build 路径的唯一判据：build 只读缓存，没见过
// 的路径后台 async 探测、落定后通知重建。
//
// 这里用 IOOverrides 造一块「网络盘」：任何同步文件 API 都记账并抛错，async `exists()`
// 等测试放闸后才回话。钉住：零同步调用、探测期间 isolate 照常跑、通知合并、并发上限、
// dispose 后不再通知、revalidateMissing 只重探「不在」的路径。

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/async_file_existence_cache.dart';

class _NetMount {
  _NetMount(this.files);

  final Set<String> files;
  final List<String> syncCalls = <String>[];
  final List<String> probes = <String>[];
  Completer<void> gate = Completer<void>();
  int inFlight = 0;
  int maxInFlight = 0;
}

class _NetFile implements File {
  _NetFile(this.path, this.mount);

  @override
  final String path;
  final _NetMount mount;

  @override
  Future<bool> exists() async {
    mount.probes.add(path);
    mount.inFlight++;
    if (mount.inFlight > mount.maxInFlight) mount.maxInFlight = mount.inFlight;
    try {
      await mount.gate.future;
      return mount.files.contains(path);
    } finally {
      mount.inFlight--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    mount.syncCalls.add('File.${invocation.memberName} $path');
    throw StateError('unexpected File.${invocation.memberName} on $path');
  }
}

Future<T> _onNetMount<T>(_NetMount mount, Future<T> Function() body) =>
    IOOverrides.runZoned<Future<T>>(
      body,
      createFile: (String path) => _NetFile(path, mount),
    );

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('lookup 零同步 IO：先回 null，探测落定后一次通知、再读命中缓存', () async {
    final _NetMount mount = _NetMount(<String>{'Z:/a/poster.jpg'});
    int notified = 0;
    await _onNetMount(mount, () async {
      final AsyncFileExistenceCache cache = AsyncFileExistenceCache(
        onChanged: () => notified++,
      );
      expect(cache.lookup('Z:/a/poster.jpg'), isNull);
      expect(cache.lookup('Z:/a/missing.jpg'), isNull);
      // 同一路径重复问不重复探测。
      expect(cache.lookup('Z:/a/poster.jpg'), isNull);

      // 网络盘还没回话：isolate 照常处理别的事件（旧实现此处整条 isolate 卡死）。
      bool timerRan = false;
      Timer.run(() => timerRan = true);
      await _flush();
      expect(timerRan, isTrue);
      expect(notified, 0);

      mount.gate.complete();
      await _flush();
      await _flush();
      expect(notified, 1, reason: '同一轮落定的探测合并成一次重建');
      expect(cache.lookup('Z:/a/poster.jpg'), isTrue);
      expect(cache.lookup('Z:/a/missing.jpg'), isFalse);
    });
    expect(mount.syncCalls, isEmpty);
    expect(mount.probes, <String>['Z:/a/poster.jpg', 'Z:/a/missing.jpg']);
  });

  test('lookupOptional：null / 空串直接 false，不探测', () async {
    final _NetMount mount = _NetMount(<String>{});
    await _onNetMount(mount, () async {
      final AsyncFileExistenceCache cache = AsyncFileExistenceCache(
        onChanged: () {},
      );
      expect(cache.lookupOptional(null), isFalse);
      expect(cache.lookupOptional(''), isFalse);
    });
    expect(mount.probes, isEmpty);
  });

  test('并发探测不超过上限（网络盘挂载端是串行 PROPFIND）', () async {
    final Set<String> files = <String>{
      for (int i = 0; i < 30; i++) 'Z:/lib/$i.jpg',
    };
    final _NetMount mount = _NetMount(files);
    await _onNetMount(mount, () async {
      final AsyncFileExistenceCache cache = AsyncFileExistenceCache(
        onChanged: () {},
        maxConcurrent: 4,
      );
      for (final String f in files) {
        cache.lookup(f);
      }
      await _flush();
      expect(mount.maxInFlight, 4);
      mount.gate.complete();
      for (int i = 0; i < 20; i++) {
        await _flush();
      }
      for (final String f in files) {
        expect(cache.lookup(f), isTrue);
      }
    });
    expect(mount.probes.length, 30);
    expect(mount.syncCalls, isEmpty);
  });

  test('revalidateMissing 只重探已知不在的路径；答案变了才通知', () async {
    final _NetMount mount = _NetMount(<String>{'Z:/a.jpg'});
    int notified = 0;
    await _onNetMount(mount, () async {
      final AsyncFileExistenceCache cache = AsyncFileExistenceCache(
        onChanged: () => notified++,
      );
      cache
        ..lookup('Z:/a.jpg')
        ..lookup('Z:/b.jpg');
      mount.gate.complete();
      await _flush();
      await _flush();
      expect(notified, 1);
      mount.probes.clear();

      // 刮削把 b.jpg 写出来了。
      mount.files.add('Z:/b.jpg');
      cache.revalidateMissing();
      // 新答案回来前旧答案照用，不闪占位。
      expect(cache.lookup('Z:/b.jpg'), isFalse);
      await _flush();
      await _flush();
      expect(mount.probes, <String>['Z:/b.jpg']);
      expect(cache.lookup('Z:/b.jpg'), isTrue);
      expect(notified, 2);

      // 再探一次答案不变：不通知。
      cache.revalidateMissing();
      await _flush();
      await _flush();
      expect(notified, 2);
    });
    expect(mount.syncCalls, isEmpty);
  });

  test('dispose 之后探测结果不再通知', () async {
    final _NetMount mount = _NetMount(<String>{'Z:/a.jpg'});
    int notified = 0;
    await _onNetMount(mount, () async {
      final AsyncFileExistenceCache cache = AsyncFileExistenceCache(
        onChanged: () => notified++,
      );
      cache.lookup('Z:/a.jpg');
      cache.dispose();
      mount.gate.complete();
      await _flush();
      await _flush();
    });
    expect(notified, 0);
  });

  testWidgets('kPendingCoverImage 停在加载态：不报错、不出帧', (WidgetTester tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Image(
          image: kPendingCoverImage,
          errorBuilder: (_, Object e, _) => throw StateError('error: $e'),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    final RawImage raw = tester.widget<RawImage>(find.byType(RawImage));
    expect(raw.image, isNull, reason: '探测落定前只是空图');
  });
}
