// 模板（入库）。拷成同目录的 `dandanplay_secret.dart` 并填入真实值。
// 真值只留本地：填好后执行一次——
//   git update-index --skip-worktree fushi/lib/src/media/video/dandanplay_secret.dart
// 真值便不显示 dirty、绝不会误提交。
//
// 真值来源：dandanplay 开放平台开发者中心 https://dev.dandanplay.com
//   创建应用（草稿需提交上线审核后凭据才对官方 API 生效）→ 拿 AppId 和「应用密钥」。
//   kDandanplayAppId     = 应用的 AppId
//   kDandanplayAppSecret = 应用密钥（密钥 1 或密钥 2 任一即可，仅用于本地签名）
//
// 两者留空（''）时，在线弹幕请求不签名（旧公共端点，官方可能拒绝 403），
// 因此未拷此文件的 fresh clone 仍能正常编译；只是官方在线弹幕匹配可能失败。
const String kDandanplayAppId = '';
const String kDandanplayAppSecret = '';
