/// 顶层 tab 的逻辑身份（取代写死的整数索引 0/1/2）。条件 tab（video/browse 常驻、
/// games 仅 Windows）用枚举身份而非位置来切换/路由——插入条件 tab 不会再打乱「设置/词典」
/// 的索引（消除 `==2` / `case 1/2` / `%3` 这类特殊情况）。底栏/侧栏只在渲染层把身份映射
/// 成位置。games（galgame 库）紧跟在 video 之后。顶层 texthooker tab 已删（galgame 捕获
/// 工作台现内嵌于 games tab，会话见 `GalHookSessionController`）。
///
/// 独立成文件（`home_page.dart` 仍 re-export）是为了让平台层（长按图标快捷方式
/// 等）只依赖这个身份枚举，而不反向 import 整个首页实现。
enum HomeTab {
  home,
  books,
  manga,
  video,

  /// 浏览（Mihon 的 Browse：来源 / 扩展 / 发现 / 下载），2026-09-27 由「下载」改名。
  browse,
  dictionaries,
  games,
  browserExtension,
  settings,
}
