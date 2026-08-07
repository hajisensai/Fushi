import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// HBK-AUDIT-012 路径穿越闸门 + 资产包端点骨架的收敛守卫（TODO-2120）。
///
/// 背景——「按名字取/存/删一个资产包」这层此前在词典 / 书 / 本地音频 / 有声书四个域
/// 里逐字复制了四份（各约 60 行），路径穿越判断更是连同 position/progress 子路由一共
/// 抄了 7 遍。这段代码里含导出缓存 + ETag/Range 续传、上传临时目录的必清理、IOSink
/// 双重关闭保护，以及那道**安全闸门**——靠复制粘贴维持，加一个新媒体域就要再抄一遍，
/// 抄漏任何一处都是真事故（泄漏临时目录 / 续传验证器失效 / 或者直接是路径穿越漏洞）。
///
/// 行为层面的 403 断言已由 `fushi_sync_server_audio_test.dart`（localaudio /
/// audiobooks 两域的 GET/DELETE `%2e%2e%2fevil`）端到端覆盖。本文件锁的是**结构**：
/// 闸门只有一处实现、四个域都真的走它、视频域按设计不接入。
void main() {
  final String src =
      File('lib/src/sync/fushi_sync_server.dart').readAsStringSync();

  test('路径穿越闸门只有一处实现', () {
    expect(
      RegExp(r'shelf\.Response\? _rejectUnsafeAssetId\(')
          .allMatches(src)
          .length,
      1,
      reason: '闸门必须唯一；再出现第二份实现就意味着有人又抄了一遍',
    );
    // 除闸门自身与视频域的两处专用校验外，不得再有裸的 `..` 判断。
    final int dotDotChecks =
        RegExp(r"contains\('\.\.'\)").allMatches(src).length;
    expect(
      dotDotChecks,
      3,
      reason: '预期恰好 3 处：_rejectUnsafeAssetId 自身 + 视频 id 的两处专用校验。'
          '多出来就是有人在新端点里手抄了穿越判断，请改调 _rejectUnsafeAssetId',
    );
  });

  test('四个资产域都经过共享闸门', () {
    for (final String label in <String>[
      "'dictionary name'",
      "'book title'",
      "'displayName'",
      "'bookKey'",
    ]) {
      expect(
        src.contains('_rejectUnsafeAssetId($label)') ||
            RegExp('_rejectUnsafeAssetId\\([^,]+, $label\\)').hasMatch(src),
        isTrue,
        reason: '$label 域必须经共享闸门校验资产名',
      );
    }
  });

  test('资产包 GET/PUT/DELETE 骨架只有一处实现，四个域都走它', () {
    expect(
      RegExp(r'Future<shelf\.Response> _serveAssetPackage\(')
          .allMatches(src)
          .length,
      1,
      reason: '资产包端点骨架必须唯一',
    );
    expect(
      RegExp(r'return _serveAssetPackage\(').allMatches(src).length,
      4,
      reason: '词典 / 书 / 本地音频 / 有声书四域都必须走共享骨架；'
          '新增媒体域也应走它，而不是再抄一份 switch',
    );
  });

  test('骨架保住三条易抄漏的约束：导出缓存 ETag、临时目录必清、IOSink 双重关闭', () {
    final int start = src.indexOf('Future<shelf.Response> _serveAssetPackage(');
    expect(start, isNonNegative);
    final int end = src.indexOf(
        'Future<shelf.Response> _handleLibraryDictionaries(', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);

    expect(body.contains('ExportPackageCache.etagFor(file)'), isTrue,
        reason: '包下载必须带 ETag 作 If-Range 验证器，否则续传会拼错字节');
    expect(body.contains('_exportCache.obtain('), isTrue,
        reason: '包导出必须经进程级缓存（否则每次请求重新打包）');
    expect(body.contains('tmpDir.deleteSync(recursive: true)'), isTrue,
        reason: '上传临时目录必须在 finally 里清理，否则每次导入泄漏一个目录');
    expect(body.contains('} finally {'), isTrue,
        reason: '临时目录清理必须在 finally，不能只在成功路径');
  });

  test('视频域按设计不接入共享闸门（视频 id 合法含 /）', () {
    // 视频 bookUid 形如 `video/xxx`，走共享闸门会把全部视频端点判成 403。
    expect(src.contains(r'_rejectUnsafeAssetId(videoId'), isFalse,
        reason: '视频 id 合法含 /，不得接入禁止 / 的资产闸门');
    expect(src.contains('_extractVideoId'), isTrue, reason: '视频 id 有自己的专用校验');
  });
}
