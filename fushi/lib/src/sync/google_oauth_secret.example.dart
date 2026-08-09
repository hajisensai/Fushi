// 模板（入库）。拷成同目录的 google_oauth_secret.dart 并填入真实 secret。
// google_oauth_secret.dart 被 .gitignore 忽略，绝不提交真值。
//
// 真值来源：Google Cloud Console → 凭据 → 「Hibiki Desktop」（桌面应用类型）
// 的 client secret（GOCSPX- 开头）。Google 把桌面 client secret 视为非机密，
// 它会编译进 app；移出入库源码只为消除扫描告警 + 让轮换后的值不再被公开。
//
// 占位符故意不用 GOCSPX- 前缀，以免触发 no_hardcoded_google_secret_test 守卫。
const String kGoogleOAuthClientSecret =
    'YOUR_GOOGLE_DESKTOP_OAUTH_CLIENT_SECRET';
