import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// BUG-4740（反馈 P1pyoS0dQb）：Android 文件分享不得再交给 share_plus。
///
/// share_plus 7.2.2 的 Android 端在 MethodChannel 回调（Android 主线程）里对每个
/// 文件整份 `File.copyTo`，大文件直接 ANR。修复后 Android 的文件分享由
/// `FushiShare` 先用异步 I/O 落快照，再经自有通道 `app.fushi.reader/share` 把
/// **快照路径**交给原生侧，原生侧只拼 Intent。这里钉住：
/// - Android 上 share_plus 通道收不到任何 `shareFiles` / `shareFilesWithResult`；
/// - 交给原生的路径都在快照根里、内容与源文件一致，且源文件删掉后快照仍在；
/// - 快照只保留本次分享，同名文件不互相覆盖。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel sharePlusChannel = MethodChannel(
    'dev.fluttercommunity.plus/share',
  );
  const MethodChannel fushiShareChannel = MethodChannel(
    'app.fushi.reader/share',
  );
  final List<MethodCall> sharePlusCalls = <MethodCall>[];
  final List<MethodCall> fushiCalls = <MethodCall>[];
  final Future<Directory> Function()? hostStagingRoot =
      FushiShare.androidShareStagingRoot;
  final Future<bool> Function(String path)? hostFileHandoff =
      FushiShare.fileHandoffWithoutShareSheet;
  late Directory sandbox;
  late Directory stagingRoot;
  Completer<void>? nativeGate;

  setUp(() {
    sharePlusCalls.clear();
    fushiCalls.clear();
    nativeGate = null;
    sandbox = Directory.systemTemp.createTempSync('fushi_share_android_');
    stagingRoot = Directory(p.join(sandbox.path, 'cache', 'fushi_share'));
    // 固定「Android 宿主」：不随跑测试的操作系统漂移。
    FushiShare.fileHandoffWithoutShareSheet = null;
    FushiShare.androidShareStagingRoot = () async => stagingRoot;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(sharePlusChannel, (
      MethodCall call,
    ) async {
      sharePlusCalls.add(call);
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(fushiShareChannel, (
      MethodCall call,
    ) async {
      fushiCalls.add(call);
      if (nativeGate != null) await nativeGate!.future;
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      sharePlusChannel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      fushiShareChannel,
      null,
    );
    FushiShare.androidShareStagingRoot = hostStagingRoot;
    FushiShare.fileHandoffWithoutShareSheet = hostFileHandoff;
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  File writeSource(String relative, String content) {
    final File f = File(p.join(sandbox.path, 'src', relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  Map<Object?, Object?> onlyNativeArgs() {
    expect(fushiCalls, hasLength(1));
    expect(fushiCalls.single.method, 'shareFiles');
    return fushiCalls.single.arguments as Map<Object?, Object?>;
  }

  List<String> pathsOf(Map<Object?, Object?> args) =>
      List<String>.from(args['paths']! as List<Object?>);

  test('宿主默认：仅 Android 走自有分享通道', () {
    expect(hostStagingRoot != null, Platform.isAndroid);
  });

  test('Android 文件分享绝不经 share_plus（其 Android 端在主线程整份拷贝）', () async {
    final File src = writeSource('clip.mp4', 'video-bytes');
    expect(
      await FushiShare.shareFiles(<XFile>[
        XFile(src.path, mimeType: 'video/mp4'),
      ], subject: 'clip'),
      isTrue,
    );
    expect(
      sharePlusCalls,
      isEmpty,
      reason: 'share_plus 7.2.2 Share.getUrisForPaths 在主线程 File.copyTo → ANR',
    );
    final Map<Object?, Object?> args = onlyNativeArgs();
    expect(args['mimeType'], 'video/mp4');
    expect(args['subject'], 'clip');
    expect(FushiShare.debugIsSharing, isFalse);
  });

  test('交给原生的是快照路径：在快照根里、内容一致、删源文件后仍可读', () async {
    final File a = writeSource('a/out.srt', 'subtitle');
    final File b = writeSource('b/out.srt', 'other');
    await FushiShare.shareFiles(<XFile>[
      XFile(a.path, mimeType: 'application/x-subrip'),
      XFile(b.path, mimeType: 'application/x-subrip'),
    ]);
    final List<String> paths = pathsOf(onlyNativeArgs());
    expect(paths, hasLength(2));
    for (final String path in paths) {
      expect(p.isWithin(stagingRoot.path, path), isTrue, reason: path);
      expect(p.basename(path), 'out.srt', reason: '接收方看到的文件名不变');
    }
    expect(paths.toSet(), hasLength(2), reason: '同名文件不能互相覆盖');
    a.deleteSync();
    b.deleteSync();
    expect(File(paths[0]).readAsStringSync(), 'subtitle');
    expect(File(paths[1]).readAsStringSync(), 'other');
  });

  test('内存型 XFile 直接写进快照根', () async {
    await FushiShare.shareFiles(<XFile>[
      XFile.fromData(
        Uint8List.fromList('log'.codeUnits),
        mimeType: 'text/plain',
      ),
    ]);
    final String path = pathsOf(onlyNativeArgs()).single;
    expect(p.isWithin(stagingRoot.path, path), isTrue);
    expect(File(path).readAsStringSync(), 'log');
  });

  test('快照根只保留本次分享（上一次的快照被清掉）', () async {
    final File src = writeSource('first.zip', '1');
    await FushiShare.shareFiles(<XFile>[XFile(src.path)]);
    final String first = pathsOf(onlyNativeArgs()).single;
    fushiCalls.clear();
    final File src2 = writeSource('second.zip', '2');
    await FushiShare.shareFiles(<XFile>[XFile(src2.path)]);
    final String second = pathsOf(onlyNativeArgs()).single;
    expect(File(first).existsSync(), isFalse);
    expect(File(second).readAsStringSync(), '2');
  });

  test('源文件在快照根里时拒绝分享，且防重入门复位', () async {
    final File inside = File(p.join(stagingRoot.path, 'x', 'y.bin'));
    inside.parent.createSync(recursive: true);
    inside.writeAsStringSync('z');
    await expectLater(
      FushiShare.shareFiles(<XFile>[XFile(inside.path)]),
      throwsArgumentError,
    );
    expect(inside.existsSync(), isTrue, reason: '不能把要分享的源文件清掉');
    expect(fushiCalls, isEmpty);
    expect(FushiShare.debugIsSharing, isFalse);
  });

  test('原生侧在途时重复分享被防重入门丢弃', () async {
    final File src = writeSource('c.mp4', 'c');
    nativeGate = Completer<void>();
    final Future<bool> first = FushiShare.shareFiles(<XFile>[XFile(src.path)]);
    await pumpEventQueueUntil(() => fushiCalls.isNotEmpty);
    expect(await FushiShare.shareFiles(<XFile>[XFile(src.path)]), isFalse);
    nativeGate!.complete();
    expect(await first, isTrue);
    expect(fushiCalls, hasLength(1));
  });

  group('reduceShareMimeTypes', () {
    test('空 / 单个 / 全相同', () {
      expect(FushiShare.reduceShareMimeTypes(<String>[]), '*/*');
      expect(
        FushiShare.reduceShareMimeTypes(<String>['image/png']),
        'image/png',
      );
      expect(
        FushiShare.reduceShareMimeTypes(<String>['video/mp4', 'video/mp4']),
        'video/mp4',
      );
    });

    test('同主类型归并成 主类型/*，跨主类型归并成 */*', () {
      expect(
        FushiShare.reduceShareMimeTypes(<String>['image/png', 'image/jpeg']),
        'image/*',
      );
      expect(
        FushiShare.reduceShareMimeTypes(<String>[
          'video/mp4',
          'application/x-subrip',
        ]),
        '*/*',
      );
    });
  });
}

/// 让出事件循环直到 [done] 成立（快照是真实异步文件 I/O，不能只 pump 一次微任务）。
Future<void> pumpEventQueueUntil(bool Function() done) async {
  for (int i = 0; i < 1000 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}
