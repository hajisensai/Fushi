// 入库默认值（空占位，保证任何 clone/worktree 都能直接编译）。模板见
// dandanplay_secret.example.dart。dandanplay 开放平台 AppId/AppSecret：客户端签名
// 在线弹幕请求需要，会编译进二进制（客户端密钥本质会随包分发，签名模式只避免明文
// 过线），故不入库真值以免被密钥扫描器反复告警。
//
// 本机要启用官方在线弹幕时：把真值填到本文件，再执行一次——
//   git update-index --skip-worktree hibiki/lib/src/media/video/dandanplay_secret.dart
// 真值只留本地、不显示 dirty、永不提交。CI 发布构建从 GitHub Actions secrets
// DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET 注入（见 build-multiplatform.yml）。
// 两者留空时在线弹幕请求自动降级为不签名（老公共端点，官方可能拒绝 403）。
const String kDandanplayAppId = '';
const String kDandanplayAppSecret = '';
