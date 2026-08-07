// 入库默认值（占位，非 GOCSPX-，保证任何 clone/worktree 都能直接编译）。
// 桌面端真值按 Google 设计属「非机密」（会编译进二进制），但不入库以免被
// 密钥扫描器反复告警。移动端(Android/iOS)走 google-services.json，不读这里。
//
// 本机要用桌面 Google Drive 登录时：把真值填到本文件，再执行一次——
//   git update-index --skip-worktree hibiki/lib/src/sync/google_oauth_secret.dart
// 真值便只留本地、不显示 dirty、永不提交（守卫 no_hardcoded_google_secret_test
// 按文件名跳过本文件）。也可改用 --dart-define=GOOGLE_OAUTH_CLIENT_SECRET=... 覆盖。
const String kGoogleOAuthClientSecret =
    'YOUR_GOOGLE_DESKTOP_OAUTH_CLIENT_SECRET';
