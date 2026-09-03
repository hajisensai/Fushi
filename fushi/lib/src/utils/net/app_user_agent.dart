/// 本 app **以自己的身份**访问第三方服务时用的 User-Agent 单一真相源。
///
/// 改名之后这些字面量散落在各调用方各写各的，于是有的报 `fushi`、有的还报
/// `Hibiki`——对外部服务而言 UA 就是这个 app 的身份，两个名字同时在跑等于同一个
/// 客户端有两个身份（限流/封禁/统计都对不上，用户也看不出哪台设备在打谁）。
///
/// **不适用**于故意伪装成浏览器的场景（Aidoku 源站需要浏览器 UA 才不被 WAF 拦、
/// Google Lens OCR 要求 Chromium UA、YouTube 分离流的回放 UA 必须与铸造 URL 时
/// 逐字一致）。那几处是「装成别人」，不是「报自己」，必须保持原样。
library;

/// 项目主页；随 UA 一起报出去，方便被访问方联系到上游。
const String kFushiUserAgentHomepage = 'https://github.com/hajisensai/fushi';

/// 组件名 [component] 的对外 UA，形如
/// `fushi/<component> (https://github.com/hajisensai/fushi)`。
///
/// [component] 用小写短横线（`shader-downloader` / `custom-fonts`），描述**是哪
/// 个子系统在发请求**——出问题时对方能直接指出是哪条链路，而不是只知道「某个
/// fushi」。
String fushiUserAgent(String component) {
  final String trimmed = component.trim();
  assert(trimmed.isNotEmpty, 'UA 组件名不能为空');
  return 'fushi/$trimmed ($kFushiUserAgentHomepage)';
}

/// OpenSubtitles 配置里存量的旧默认 UA。
///
/// 这条 UA 被序列化进 `video_subtitle_opensubtitles_config` 偏好，存量用户的
/// JSON 里躺着的就是它——只改构造默认值改不动已经落盘的那一份。解码时把**恰好
/// 等于旧默认值**的那一份归一到新默认值（用户自己填过的自定义 UA 原样保留）。
const String kLegacyOpenSubtitlesUserAgent = 'Hibiki v1';
