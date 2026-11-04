import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/remote_subtitle_catalog.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 反馈 1QkmT2vVTm「我的互联日语字幕消失了」。
///
/// 根因：`_loadRemoteEpisode` 只在「这一集没有持久化字幕选择」时才下载 host 默认
/// 字幕，而菜单「服务端字幕」行唯一的数据源 `_remoteSubtitlePath` 只在那条分支里赋值。
/// 用户关过一次字幕（`off:`）、或选过一次内嵌英文轨（`embedded:0`），重进后 host 上的
/// 日语 sidecar 就不再出现在字幕菜单里，再也选不回来。
///
/// 修法：「列不列」与「挂不挂」拆开——[planRemoteBackendDefaultSubtitle] 给出计划，
/// 有选择时走 listOnly：起播后照样下载登记成菜单行，只是不挂到播放上。
///
/// 播放页在 headless test 里跑不起真播放器（见
/// video_remote_default_subtitle_failure_guard_test），页面接线用源码守卫钉住。
void main() {
  group('planRemoteBackendDefaultSubtitle', () {
    test('后端没有默认字幕 → none', () {
      expect(
        planRemoteBackendDefaultSubtitle(
          backendOffersDefault: false,
          selectionRestored: false,
          hasPreresolvedCues: false,
        ),
        RemoteBackendDefaultSubtitlePlan.none,
      );
      expect(
        planRemoteBackendDefaultSubtitle(
          backendOffersDefault: false,
          selectionRestored: true,
          hasPreresolvedCues: true,
        ),
        RemoteBackendDefaultSubtitlePlan.none,
      );
    });

    test('没有别的选择 → apply（起播挂上）', () {
      expect(
        planRemoteBackendDefaultSubtitle(
          backendOffersDefault: true,
          selectionRestored: false,
          hasPreresolvedCues: false,
        ),
        RemoteBackendDefaultSubtitlePlan.apply,
      );
    });

    test('已恢复上次选择（关闭 / 内嵌轨 / 本机档）→ 仍要列出，只是不挂', () {
      expect(
        planRemoteBackendDefaultSubtitle(
          backendOffersDefault: true,
          selectionRestored: true,
          hasPreresolvedCues: false,
        ),
        RemoteBackendDefaultSubtitlePlan.listOnly,
      );
    });

    test('预解析轨优先挂上时，后端默认字幕也照样列出', () {
      expect(
        planRemoteBackendDefaultSubtitle(
          backendOffersDefault: true,
          selectionRestored: false,
          hasPreresolvedCues: true,
        ),
        RemoteBackendDefaultSubtitlePlan.listOnly,
      );
    });
  });

  group('播放页接线（源码守卫）', () {
    late String src;
    setUpAll(() => src = maskComments(readVideoFushiSource()));

    String methodBody(String signature) {
      final int start = src.indexOf(signature);
      expect(start, greaterThan(-1), reason: '缺少 $signature');
      final int end = src.indexOf('\n  }\n', start);
      expect(end, greaterThan(start));
      return src.substring(start, end);
    }

    test('计划由已恢复的选择驱动，而不是选择本身挡掉下载', () {
      final String load = methodBody('Future<void> _loadRemoteEpisode(');
      final int planAt = load.indexOf('planRemoteBackendDefaultSubtitle(');
      expect(planAt, greaterThan(-1));
      expect(
        load.indexOf('selectionRestored: subtitleResolved', planAt),
        greaterThan(planAt),
      );
      // 旧写法：`else if (urls.subtitleUrl != null)` 挂在 `if (subtitleResolved)`
      // 的 else 链上，选择一旦恢复就不下载。
      expect(load.contains('} else if (urls.subtitleUrl != null) {'), isFalse);
    });

    test('listOnly 在起播成功后登记菜单行，且换集作废', () {
      final String load = methodBody('Future<void> _loadRemoteEpisode(');
      final int listAt = load.indexOf(
        'backendDefaultPlan == RemoteBackendDefaultSubtitlePlan.listOnly',
      );
      expect(listAt, greaterThan(-1), reason: 'listOnly 分支必须存在');
      final int applyLoadAt = load.indexOf('_applyLoad(');
      expect(listAt, greaterThan(applyLoadAt), reason: '不拖慢起播：起播后再取');
      expect(
        load.indexOf('_listRemoteBackendDefaultSubtitle(', listAt),
        greaterThan(listAt),
      );

      final String list = methodBody(
        'Future<void> _listRemoteBackendDefaultSubtitle(',
      );
      final int seqAt = list.indexOf('seq != _episodeLoadSeq');
      final int assignAt = list.indexOf('_remoteSubtitlePath = subtitle.path');
      expect(seqAt, greaterThan(-1), reason: '换集后迟到的结果不得写进新集');
      expect(assignAt, greaterThan(seqAt));
      expect(
        list.indexOf('cues.isEmpty'),
        allOf(greaterThan(-1), lessThan(assignAt)),
        reason: '解析不出 cue 的文件不登记成可选行',
      );
      // 只列不挂：不得碰主字幕选择与播放器 cue。
      expect(list.contains('_currentSubtitleSource'), isFalse);
      expect(list.contains('setCues('), isFalse);
    });
  });
}
