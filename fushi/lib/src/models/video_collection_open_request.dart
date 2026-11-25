import 'package:flutter/foundation.dart';

/// 「请视频库打开某个视频合集的详情页」的待处理请求（`media_collections.id`）；
/// null = 没有。与书架的 `shelfCollectionOpenRequest` 同一范式。
///
/// 为什么走请求而不是调用方自己 push 详情页：视频合集的成员是跨端 union——
/// Jellyfin / Emby 混排、互联 host 的集以「本机没有的 entryKey」挂在合集里，只有
/// 视频库页（`HomeVideoPage`）持有解析它们的远端上下文（远端清单、鉴权封面、流播 /
/// 下载入口，`CollectionRemoteContext`），以及合集详情页的删除 / 重刮 / AI 等回调。
/// 别处另拼一份详情页就是第二套、而且看不见远端集的渲染（「同一作品」点开 Jellyfin
/// 上的动画显示「合集为空」）。调用方切到视频 tab 并发请求，由视频库页用它唯一的
/// `_openCollectionDetail` 打开——与在视频库点合集卡同一个出口。
///
/// 视频库页订阅它，并在首次构建后检查一次（tab 懒构建时请求先于页面存在）。
final ValueNotifier<int?> videoCollectionOpenRequest = ValueNotifier<int?>(
  null,
);

/// 发一次打开请求（覆盖尚未被接走的旧请求——只有最后一次点击算数）。
void requestVideoCollectionOpen(int collectionId) {
  videoCollectionOpenRequest.value = collectionId;
}

/// 视频库页接单：取走并清空待处理请求，返回合集 id；没有请求返回 null。
int? takeVideoCollectionOpenRequest() {
  final int? collectionId = videoCollectionOpenRequest.value;
  videoCollectionOpenRequest.value = null;
  return collectionId;
}
