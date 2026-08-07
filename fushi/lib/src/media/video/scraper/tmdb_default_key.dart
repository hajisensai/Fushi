// 入库默认值（空占位，保证任何 clone/worktree 都能直接编译）。模板见
// tmdb_default_key.example.dart。
//
// 内置 TMDB API key（v3 auth）——让封面/元数据刮削开箱即用，用户不必自己去
// themoviedb.org 申请再粘贴。key 会编译进二进制（客户端密钥本质会随包分发），故
// **不入库真值**，以免被密钥扫描器反复告警、也避免轮换后的新值随每次 commit 重新公开。
// 同 google_oauth_secret.dart / dandanplay_secret.dart 的既有约定。
//
// 本机要启用内置 key 时：把真值填到本文件，再执行一次——
//   git update-index --skip-worktree hibiki/lib/src/media/video/scraper/tmdb_default_key.dart
// 真值只留本地、不显示 dirty、永不提交。CI 发布构建从 GitHub Actions secret
// TMDB_API_KEY 注入（见 main.yml / build-multiplatform.yml）。
//
// 留空时 TMDB 源自动降级为「未配置」：不构造 client、UI 不出 TMDB 候选，其余数据源
// （Bangumi / AniList / Jikan / 离线库）照常工作。fork 构建请填自己申请的 key。
//
// ⚠️ 使用本 key 附带合约义务（TMDB Terms of Use）：应用内须展示 TMDB logo 与
// "This product uses the TMDB API but is not endorsed or certified by TMDB."
// ——见「关于」页署名区。删 key 前不要先删署名，反之亦然。
const String kBuiltinTmdbApiKey = '';

/// 用户自定义 TMDB API key 的偏好键（存 Drift `preferences` 表，不改 schema）。
///
/// 与 [kBuiltinTmdbApiKey] 同住一个文件是有意的：「这次请求用哪把 key」的全部输入
/// 就是这两者，分散在 UI 文件里会让人以为改弹窗就能改取值规则。
const String kVideoScraperTmdbApiKeyPref = 'video_scraper_tmdb_api_key';

/// 解析实际生效的 TMDB key：**用户自填优先，其次内置**。
///
/// 两者皆空 → 返回空串，调用方据此判定「TMDB 未配置」并跳过该源。返回空串是**正常
/// 降级路径不是错误**：fresh clone / fork 构建本就没有内置 key。
String resolveTmdbApiKey(String userKey) {
  final String trimmed = userKey.trim();
  return trimmed.isEmpty ? kBuiltinTmdbApiKey.trim() : trimmed;
}
