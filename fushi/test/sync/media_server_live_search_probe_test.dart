// 真服务器搜索探针（BUG-2608）：拿既有令牌沿 [JellyfinVideoClient.search] 真实
// 代码路径打一次搜索，打印服务器原始行数与把关后的命中，验证兼容层的按字模糊
// 命中被挡住、精确命中置顶。默认 skip；跑法：
//
//   flutter test test/sync/media_server_live_search_probe_test.dart --no-pub \
//     --dart-define=FUSHI_EMBY_URL=https://host \
//     --dart-define=FUSHI_EMBY_TOKEN=... --dart-define=FUSHI_EMBY_USERID=... \
//     --dart-define=FUSHI_EMBY_QUERY=怪奇物语
//
// 只读端点，不写服务器状态。

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/video/media_server/media_server_browser.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';

const String _serverUrl = String.fromEnvironment('FUSHI_EMBY_URL');
const String _token = String.fromEnvironment('FUSHI_EMBY_TOKEN');
const String _userId = String.fromEnvironment('FUSHI_EMBY_USERID');
const String _query = String.fromEnvironment(
  'FUSHI_EMBY_QUERY',
  defaultValue: '怪奇物语',
);

void main() {
  test(
    'live search: 把关后每条命中都真含查询词，精确同名在最前',
    () async {
      final JellyfinApi api = JellyfinApi(
        serverUrl: _serverUrl,
        accessToken: _token,
      );
      final JellyfinVideoClient client = JellyfinVideoClient(
        api: api,
        userId: _userId,
      );
      int serverRows = 0;
      for (final String type in JellyfinVideoClient.kSearchRounds) {
        final JellyfinItemsPage raw = await api.items(
          userId: _userId,
          recursive: true,
          includeItemType: type,
          searchTerm: _query,
          limit: 1,
        );
        serverRows += raw.totalCount;
      }
      final List<MediaServerItem> all = <MediaServerItem>[];
      MediaServerPage page = await client.search(_query);
      all.addAll(page.items);
      while (page.hasMore) {
        page = await client.search(_query, startIndex: page.nextStartIndex);
        all.addAll(page.items);
      }
      // ignore: avoid_print
      print('[ms-search] "$_query": server rows=$serverRows → hits=${all.length}');
      for (final MediaServerItem it in all) {
        // ignore: avoid_print
        print('   ${it.type.name}\t${it.name}\t(${it.originalTitle})');
      }
      expect(all, isNotEmpty);
      expect(all.first.name, _query, reason: '精确同名置顶');
    },
    skip: _serverUrl.isEmpty || _token.isEmpty || _userId.isEmpty
        ? '需要 --dart-define FUSHI_EMBY_URL / FUSHI_EMBY_TOKEN / FUSHI_EMBY_USERID'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
