enum VideoLibrarySection {
  home,
  series,
  allVideos,

  /// 用户自己登录的媒体服务器（Jellyfin / Emby），按服务器自己的树浏览。
  mediaServers,

  /// 视频在线发现（与「浏览 › 发现 › 视频」同一个生产发现页）。
  discover,

  /// 已装视频源扩展（Aniyomi）提供的在线源（与「浏览 › 来源」同一组件）。
  onlineSources,

  /// 视频源扩展目录，仓库在页头动作（与「浏览 › 扩展」同一组件）。
  extensions,
  sources,
  settings
}
