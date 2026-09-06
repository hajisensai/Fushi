import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  test(
    'live VideoBook deletion entries use one delete-and-reclaim operation',
    () {
      final String home = File(
        'lib/src/pages/implementations/home_video_page.dart',
      ).readAsStringSync();
      final String player = File(
        'lib/src/pages/implementations/video_fushi_page.dart',
      ).readAsStringSync();
      final String host = File(
        'lib/src/sync/app_model_library_host_service.dart',
      ).readAsStringSync();
      final String appModel = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      final String pipeline = File(
        'lib/src/media/video/download/video_download_pipeline_service.dart',
      ).readAsStringSync();

      final String libraryDelete = File(
        'lib/src/media/video/video_library_delete.dart',
      ).readAsStringSync();
      final Map<String, ({String body, String operation})>
      entries = <String, ({String body, String operation})>{
        // 视频页两个入口经 deleteVideoBooksWithDecision（同时删本地文件 + 联动
        // 下载任务）落到仓库层；helper 自身再由下一条守住「必须走 reclaim 操作」。
        'home batch delete': (
          body: methodBody(home, 'Future<void> _batchDeleteConfirm() async'),
          operation: 'deleteVideoBooksWithDecision',
        ),
        'home single delete': (
          body: methodBody(
            home,
            'Future<void> _confirmDelete(VideoBookRow book) async',
          ),
          operation: 'deleteVideoBooksWithDecision',
        ),
        'library delete helper': (
          body: topLevelFunctionBody(
            libraryDelete,
            'deleteVideoBooksWithDecision',
          )!,
          operation: 'deleteVideoBooksAndReclaimAssets',
        ),
        'missing-resource delete': (
          body: methodBody(
            player,
            'Future<void> _confirmMissingResourceDelete(VideoBookRow row) async',
          ),
          operation: 'deleteVideoBookAndReclaimAssets',
        ),
        'host remote delete': (
          body: methodBody(host, 'Future<void> deleteVideo(String id) async'),
          operation: 'deleteVideoBookAndReclaimAssets',
        ),
        'confirmed sync deletion': (
          body: methodBody(appModel, 'Future<void> _applyConfirmedDeletions('),
          operation: 'deleteVideoBookAndReclaimAssets',
        ),
        'download-job deletion': (
          body: topLevelFunctionBody(
            pipeline,
            'deletePersistedVideoDownloadJob',
          )!,
          operation: 'deleteVideoBookAndReclaimAssets',
        ),
      };

      for (final entry in entries.entries) {
        expect(
          containsIdentifierCall(entry.value.body, entry.value.operation),
          isTrue,
          reason:
              '${entry.key} must keep DB mutation and asset reclaim in one '
              'VideoScrapeOperationGate lease',
        );
        expect(
          containsIdentifierCall(entry.value.body, 'deleteVideoBook'),
          isFalse,
          reason:
              '${entry.key} must not expose a maintenance entry gap after '
              'the live DB row is deleted',
        );
        expect(
          containsIdentifierCall(
            entry.value.body,
            'reclaimDeletedVideoBookAssets',
          ),
          isFalse,
          reason: '${entry.key} must not start reclaim under a second lease',
        );
      }
    },
  );

  test(
    '_loadLibraryMaps is latest-request-wins across scrape cleanup refresh',
    () {
      final String source = File(
        'lib/src/pages/implementations/home_video_page.dart',
      ).readAsStringSync();
      expect(
        RegExp(
          r'int\s+_libraryMapsRequestGeneration\s*=\s*0\s*;',
        ).hasMatch(maskComments(source)),
        isTrue,
      );

      // 预取链的全体，不是某一个方法名。`_loadLibraryMaps` 后来拆成「代次
      // 薄壳 + `_loadLibraryMapsInner` 真身」，代次检查随之搬进 Inner——只盯外层
      // 名字会把一次纯重构报成回归（实际就在 2026-08-28 批量合并里报了）。
      // 取并集后拆分/合并都不会假红；整条链被改名则 [methodBody] 会自己报缺失。
      final List<String> chain = <String>[
        'Future<void> _loadLibraryMaps() async',
        'Future<void> _loadLibraryMapsInner(int requestGeneration) async',
      ].where(source.contains).toList();
      expect(chain, isNotEmpty, reason: '预取链上的方法全部消失（改名？）');
      final String body = compactCode(
        chain.map((String sig) => methodBody(source, sig)).join('\n'),
      );
      const String request =
          'finalintrequestGeneration=++_libraryMapsRequestGeneration;';
      const String staleGuard =
          'if(!mounted||requestGeneration!=_libraryMapsRequestGeneration)return;';
      expect(body, contains(request));
      expect(body, contains(staleGuard));
      // 锚点不带 `await`：预取链把十三个全表查询改成「先全部发出去、后统一
      // Future.wait」，第一个快照因此是 `db.getAllMediaCollections()` 而不再是
      // `await db.…`。不变式没变（代次仍必须在第一次碰库之前捕获），变的只是
      // 那一行的写法——所以这里钉的是「发出查询」这个点，不是 await 那个点。
      const String firstSnapshot = 'db.getAllMediaCollections()';
      expect(body, contains(firstSnapshot), reason: '预取链不再碰这张表？守卫需更新');
      expect(
        body.indexOf(request),
        lessThan(body.indexOf(firstSnapshot)),
        reason: 'generation must be captured before the first library snapshot',
      );
      expect(
        body.indexOf(staleGuard),
        lessThan(body.indexOf('setState((){')),
        reason: 'a pre-cleanup slow snapshot must be rejected before setState',
      );
    },
  );
}
