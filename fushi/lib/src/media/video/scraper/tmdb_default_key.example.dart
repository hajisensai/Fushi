/// 用户自定义 TMDB API key 的偏好键：定义在引擎 `media_pref_keys.dart`（服务端刮削
/// 装配也读它），这里再导出——与 [kBuiltinTmdbApiKey] 同住一个文件是有意的：「这次
/// 请求用哪把 key」的全部输入就是这两者，分散在 UI 文件里会让人以为改弹窗就能改
/// 取值规则。（指令必须在声明之前，故放在文件头注释之后、第一个 const 之前。）
export 'package:fushi_engine/media/media_pref_keys.dart'
    show kVideoScraperTmdbApiKeyPref;

// 模板（入库）。把真值填进同目录的 `tmdb_default_key.dart`，再执行一次：
//   git update-index --skip-worktree fushi/lib/src/media/video/scraper/tmdb_default_key.dart
// 真值只留本地、不显示 dirty、永不提交。
//
// 真值来源：https://www.themoviedb.org/settings/api → Developer Plan（免费，非商业）
//   - 应用名称：Hibiki
//   - 应用网址：https://github.com/hajisensai/fushi
//   - 使用类型：按实际分发面选 Desktop / Mobile Application（**不要选 Personal**，
//     本项目是公开分发的应用，不是个人自用）
//   - 拿「API 密钥」那一串 32 位十六进制（v3 auth），不是 v4 读访问令牌
//
// CI 发布构建从 GitHub Actions secret TMDB_API_KEY 注入，无需改本文件。
//
// 留空时 TMDB 源自动降级为「未配置」，其余数据源照常工作。
const String kBuiltinTmdbApiKey = '';

/// 解析实际生效的 TMDB key：用户自填优先，其次内置。两者皆空 = TMDB 未配置。
String resolveTmdbApiKey(String userKey) {
  final String trimmed = userKey.trim();
  return trimmed.isEmpty ? kBuiltinTmdbApiKey.trim() : trimmed;
}
