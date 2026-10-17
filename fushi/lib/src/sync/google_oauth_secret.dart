// GITIGNORED — 不入库（见 .gitignore）。本机/CI 本地存在，git 永不追踪。
//
// 这里放 Google「桌面应用」OAuth 客户端（Hibiki Desktop）的 client secret。
// Google 设计上把桌面 client secret 视为「非机密」：它必然随二进制分发，token
// 交换时还强制要求带上（即便已用 PKCE）。我们仍把真值移出入库源码，只为：
//   ① 不再被 GitGuardian 等扫描器反复告警；
//   ② 在 Console 轮换旧 secret 后，新值不会随每次 commit 重新公开。
//
// 轮换流程：Google Cloud Console → 凭据 → 「Hibiki Desktop」→ 重置 client
// secret → 把新值填到下面这一行（只改这一行，别动其它文件）。
//
// 新机器/CI 首次构建：把 google_oauth_secret.example.dart 拷成本文件并填真值，
// 否则 google_drive_auth.dart 的 import 会编译失败。
const String kGoogleOAuthClientSecret = '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';
