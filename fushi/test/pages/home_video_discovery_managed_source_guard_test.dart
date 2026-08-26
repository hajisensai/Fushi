import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1872 接线守卫：视频发现的**两条**流程在「下载后端已就绪、只是没有受管视频
/// 来源」时，必须走 `_managedVideoDownloadSourcesOrPrompt`（弹引导 + 就地补来源），
/// 不得回到那句 `media_source_no_sources`（「暂无来源」）。
///
/// 为什么必须是源码守卫、而不是再写一条 widget 测试：bug 的原始路径在
/// `home_page.dart` 的 `_openVideoDiscoveryResourceSearch` / `_openVideoDiscovery
/// Subscription` 里，两者都要真 `AppModel`（Drift + 下载后端 + 资源注册表）才能跑到
/// 那个分支。`managed_video_source_prompt_test.dart` 只覆盖了新对话框组件本身——把
/// 这两处接线改回旧的 `sources.isEmpty → snackbar` 写法，那些测试全绿。接线本身
/// 因此零覆盖，只能在源码层钉。
///
/// 同时钉住第三条：引导返回 true 只表示用户走进了来源对话框，**不表示真加成了**。
/// 重读仍为空时必须给回一句提示——这条路径上没有可停留的空态门（下载页有），
/// 静默返回等于整个流程无声消失，比修前那句 snackbar 还糟。
void main() {
  late String src;

  setUpAll(() {
    final File file = File('lib/src/pages/implementations/home_page.dart');
    expect(file.existsSync(), isTrue, reason: '文件不存在');
    src = file.readAsStringSync();
  });

  test('两个入口都走 _managedVideoDownloadSourcesOrPrompt', () {
    for (final String signature in <String>[
      'Future<void> _openVideoDiscoveryResourceSearch(',
      'Future<void> _openVideoDiscoverySubscription(',
    ]) {
      final String body = methodBody(src, signature);
      expect(
        containsIdentifierCall(body, '_managedVideoDownloadSourcesOrPrompt'),
        isTrue,
        reason: '$signature 必须经统一出口拿来源清单（缺来源时弹引导），'
            '不能自己裸调 getManagedVideoDownloadSources 后甩一句提示',
      );
      expect(
        containsIdentifier(maskCommentsAndStrings(body),
            'getManagedVideoDownloadSources'),
        isFalse,
        reason: '$signature 不得绕过统一出口直接读来源清单',
      );
    }
  });

  test('这三处不得再出现 media_source_no_sources（那是通用扫描根的「暂无来源」）', () {
    // 只钉这条路径上的三个方法体：同一个 key 在 `_scrapeAllVideosFromSources`
    // 里是**对的**（那里缺的真是本地扫描根），全文件禁用会把它一起误伤。
    for (final String signature in <String>[
      'Future<void> _openVideoDiscoveryResourceSearch(',
      'Future<void> _openVideoDiscoverySubscription(',
      'Future<List<MediaSourceRow>> _managedVideoDownloadSourcesOrPrompt(',
    ]) {
      expect(
        containsIdentifier(
          maskCommentsAndStrings(methodBody(src, signature)),
          'media_source_no_sources',
        ),
        isFalse,
        reason: '$signature 缺的是下载落地用的本地视频文件夹，不是「暂无来源」——'
            '用错 key 正是用户猜成「没配下载后端」的原因',
      );
    }
  });

  test('引导后重读仍为空：必须给回提示，不得静默返回', () {
    final String body = methodBody(
      src,
      'Future<List<MediaSourceRow>> _managedVideoDownloadSourcesOrPrompt(',
    );
    expect(containsIdentifierCall(body, 'promptManagedVideoSourceSetup'), isTrue,
        reason: '为空时必须弹引导');
    expect(
      containsIdentifierCall(body, '_showVideoDiscoveryMessage'),
      isTrue,
      reason: '重读仍为空时必须说清缺什么；这条路径上没有可停留的空态门，'
          '静默返回 = 界面上什么都不发生',
    );
    expect(
      containsIdentifier(
          maskCommentsAndStrings(body), 'download_no_managed_video_source'),
      isTrue,
      reason: '补的提示必须是「缺落地用的本地视频文件夹」这句，不是通用「暂无来源」',
    );
  });
}
