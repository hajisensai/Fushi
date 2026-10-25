// NativeScratch（本包唯一的长寿命原生暂存区 owner）的生命周期：
//
// 1. 短命 isolate 退出后它分配的原生块被释放（NativeFinalizer 在 isolate 关闭时跑）。
//    对账办法：子 isolate 申请一块 64 MiB 暂存区并写首页，把地址交回主 isolate；
//    退出前该地址必须是已提交的映射（探针自检，防空壳），退出后必须已归还操作系统。
//    64 MiB 远超 Windows 堆的直接 VirtualAlloc 门槛与 glibc 的 mmap 门槛上限（32 MiB），
//    free 必然 VirtualFree / munmap，探针看得到；不走任何生产代码里的计数器（零生产负担）。
// 2. 冷 isolate 首次零长请求也拿到非空指针（与暖缓存同一形态），见 HBK-AUDIT-006。
@TestOn('vm')
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_compute/src/native_scratch.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';
import 'package:test/test.dart';

const int _probeBytes = 64 << 20;

/// Windows `MEMORY_BASIC_INFORMATION`（x64 布局，Dart Struct 自动补齐对齐）。
final class _MemoryBasicInformation extends Struct {
  external Pointer<Void> baseAddress;
  external Pointer<Void> allocationBase;
  @Uint32()
  external int allocationProtect;
  @Uint16()
  external int partitionId;
  @Size()
  external int regionSize;
  @Uint32()
  external int state;
  @Uint32()
  external int protect;
  @Uint32()
  external int type;
}

typedef _VirtualQueryC =
    Size Function(Pointer<Void>, Pointer<_MemoryBasicInformation>, Size);
typedef _VirtualQueryDart =
    int Function(Pointer<Void>, Pointer<_MemoryBasicInformation>, int);
typedef _MsyncC = Int32 Function(Pointer<Void>, Size, Int32);
typedef _MsyncDart = int Function(Pointer<Void>, int, int);

const int _memCommit = 0x1000;
const int _msAsync = 1;
const int _pageSize = 4096;

/// [address] 所在页当前是否仍是本进程已提交 / 已映射的内存。
bool _isMapped(int address) {
  if (Platform.isWindows) {
    final _VirtualQueryDart query = DynamicLibrary.open(
      'kernel32.dll',
    ).lookupFunction<_VirtualQueryC, _VirtualQueryDart>('VirtualQuery');
    final Pointer<_MemoryBasicInformation> info =
        calloc<_MemoryBasicInformation>();
    try {
      final int n = query(
        Pointer<Void>.fromAddress(address),
        info,
        sizeOf<_MemoryBasicInformation>(),
      );
      if (n == 0) return false;
      return info.ref.state == _memCommit;
    } finally {
      calloc.free(info);
    }
  }
  // POSIX：msync 对未映射的页返回 -1（ENOMEM）。
  final _MsyncDart msync = DynamicLibrary.process()
      .lookupFunction<_MsyncC, _MsyncDart>('msync');
  final int page = address & ~(_pageSize - 1);
  return msync(Pointer<Void>.fromAddress(page), _pageSize, _msAsync) == 0;
}

/// 子 isolate：申请一块大暂存区、写首页，把地址交回去后等主 isolate 放行再退出。
void _scratchChild(List<Object> args) {
  final SendPort reply = args[0] as SendPort;
  final int bytes = args[1] as int;
  final ReceivePort release = ReceivePort();
  final NativeScratch scratch = NativeScratch();
  final Pointer<Uint8> ptr = scratch.reserve(bytes);
  ptr.asTypedListOutOfLine(_pageSize).fillRange(0, _pageSize, 0x5a);
  reply.send(<Object>[ptr.address, release.sendPort]);
  release.first.then((_) {
    release.close();
    // 保证 scratch 在等待期间一直可达（等的是 isolate 退出，不是 GC）。
    reply.send(scratch.reserve(bytes).address);
  });
}

void main() {
  test(
    'a short-lived isolate releases its NativeScratch block on exit',
    () async {
      final ReceivePort reply = ReceivePort();
      final ReceivePort exit = ReceivePort();
      final StreamIterator<Object?> replies = StreamIterator<Object?>(reply);
      await Isolate.spawn<List<Object>>(_scratchChild, <Object>[
        reply.sendPort,
        _probeBytes,
      ], onExit: exit.sendPort);

      expect(await replies.moveNext(), isTrue);
      final List<Object?> hello = replies.current! as List<Object?>;
      final int address = hello[0]! as int;
      final SendPort release = hello[1]! as SendPort;
      expect(address, isNot(0));
      // 探针自检：子 isolate 还活着时这块内存必须看得见，否则下面的断言是空壳。
      expect(
        _isMapped(address),
        isTrue,
        reason: 'probe must see the live block',
      );

      release.send(null);
      expect(await replies.moveNext(), isTrue);
      expect(replies.current, address);
      await exit.first;
      await replies.cancel();

      expect(
        _isMapped(address),
        isFalse,
        reason: 'NativeScratch block must be freed when its isolate exits',
      );
    },
    testOn: 'windows || linux',
  );

  test('a cold NativeScratch hands out a non-null block for 0 bytes', () async {
    // 每个断言都在全新的 isolate 里做，保证是这块暂存区的第一次请求。
    final int address = await Isolate.run(
      () => NativeScratch().reserve(0).address,
    );
    expect(address, isNot(0));
    final int input = await Isolate.run(
      () => NativeScratch.input.reserve(0).address,
    );
    expect(input, isNot(0));
    final int fixed = await Isolate.run(
      () => NativeScratch.fixed(8).pointer.address,
    );
    expect(fixed, isNot(0));
  });

  // HBK-AUDIT-006：空 / 坏图在冷 isolate 的第一次调用与暖缓存之后同样返回 null（旧契约），
  // 不能冷的时候把 nullptr 交给原生侧、拿回 NULL_ARGUMENT 抛 StateError。
  group('empty image as the very first call of a fresh isolate', () {
    final Map<String, Object? Function()> calls = <String, Object? Function()>{
      'decode': () => FushiComputeImage.instance.decode(Uint8List(0)),
      'probe': () => FushiComputeImage.instance.probe(Uint8List(0)),
      'toJpeg': () =>
          FushiComputeImage.instance.toJpeg(Uint8List(0), quality: 80),
      'coverSignature': () =>
          FushiComputeImage.instance.coverSignature(Uint8List(0)),
      'decodePng': () => FushiComputeImage.instance.decodePng(Uint8List(0)),
    };
    for (final MapEntry<String, Object? Function()> call in calls.entries) {
      test(call.key, () async {
        final Object? Function() body = call.value;
        final String cold = await Isolate.run(() => '${body()}');
        expect(cold, 'null');
        // 暖缓存（先跑一次有效大小的请求）之后形态一致。
        final String warm = await Isolate.run(() {
          NativeScratch.input.reserve(1 << 10);
          return '${body()}';
        });
        expect(warm, cold);
      });
    }
  });
}
