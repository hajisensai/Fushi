import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/metadata/video_library_scrape_sweep.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_ai_identity.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_sweep_ledger.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';

import 'package:fushi/src/media/video/metadata/video_scrape_runtime.dart';

/// 未指派 AI 的顾问：协调器完全不问它。
class _NoAi implements AiVideoIdentityAdvisor {
  @override
  String? get capabilityKey => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('不应调用 ${invocation.memberName}');
}

/// HomePage 私有刮削状态搬到 [VideoScrapeRuntime] 后的生命周期契约：惰性建、
/// 按配置指纹重建、补刮调度器跟随控制器、关停后可重建。
void main() {
  late FushiDatabase db;
  late VideoSourceScrapeGlobalConfig config;
  late int taskChanges;
  late int libraryChanges;
  late VideoScrapeRuntime runtime;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    config = const VideoSourceScrapeGlobalConfig();
    taskChanges = 0;
    libraryChanges = 0;
    runtime = VideoScrapeRuntime(
      database: () => db,
      readConfig: () => config,
      createAiIdentityAdvisor: _NoAi.new,
      isAutoBackfillEnabled: () => true,
      createLedger: VideoScrapeSweepLedger.new,
      onTaskChanged: () => taskChanges++,
      onLibraryChanged: () => libraryChanges++,
    );
  });

  tearDown(() async {
    runtime.shutdown();
    await db.close();
  });

  test('惰性构建：没人要过时 currentController 为 null，之后复用同一个', () {
    expect(runtime.currentController, isNull);
    final VideoSourceScrapeTaskController first = runtime.controller;
    expect(runtime.currentController, same(first));
    expect(runtime.controller, same(first));
    final VideoLibraryScrapeSweep sweep = runtime.sweep;
    expect(runtime.sweep, same(sweep));
    expect(runtime.controller, same(first), reason: '读 sweep 不应重建控制器');
  });

  test('配置指纹变了（且不忙）才重建控制器与补刮调度器', () {
    final VideoSourceScrapeTaskController first = runtime.controller;
    final VideoLibraryScrapeSweep firstSweep = runtime.sweep;

    config = const VideoSourceScrapeGlobalConfig();
    expect(runtime.controller, same(first), reason: '同一份配置不重建');

    config = const VideoSourceScrapeGlobalConfig(tmdbApiKey: 'changed');
    final VideoSourceScrapeTaskController second = runtime.controller;
    expect(second, isNot(same(first)));
    expect(runtime.sweep, isNot(same(firstSweep)), reason: '补刮器跟随控制器重建');
  });

  test('任务监听跟着控制器走：重建后挂在新控制器上', () async {
    runtime.controller;
    config = const VideoSourceScrapeGlobalConfig(tmdbApiKey: 'changed');
    final VideoSourceScrapeTaskController second = runtime.controller;
    taskChanges = 0;
    // 来源扫描开始 / 结束各通知一次。
    await second.runSourceScan<void>(1, () async {});
    expect(taskChanges, 2);
  });

  test('shutdown 清空当前控制器，再取时按当前配置重建', () {
    final VideoSourceScrapeTaskController first = runtime.controller;
    runtime.shutdown();
    expect(runtime.currentController, isNull);
    final VideoSourceScrapeTaskController again = runtime.controller;
    expect(again, isNot(same(first)));
  });

  test('observe：成功结束通知库变更并原样返回结果', () async {
    const SourceScrapeReport report = SourceScrapeReport(
      sourceIds: <int>[1],
      totalWorks: 1,
      succeededWorks: 1,
    );
    final SourceScrapeReport result = await runtime.observe(
      Future<SourceScrapeReport>.value(report),
    );
    await Future<void>.delayed(Duration.zero);
    expect(result, same(report));
    expect(libraryChanges, 1);
  });
}
