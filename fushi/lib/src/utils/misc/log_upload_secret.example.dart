// 模板（入库）。拷成同目录的 `log_upload_secret.dart` 并填入真实值。
// `log_upload_secret.dart` 被 .gitignore 忽略，绝不提交真值（端点 + token）。
//
// 真值来源：你部署的日志接收端（Cloudflare Worker 等），
// 见 server/cf-worker/DEPLOYMENT_SECRETS.local.md：
//   kLogUploadEndpoint = 'https://logs.<你的域名>/api/logs'
//   kLogUploadToken    = 接收端的 UPLOAD_TOKEN
//
// 端点留空（''）时，日志页的「上传」按钮自动隐藏；
// 因此未拷此文件的 fresh clone 仍能正常编译/构建（按钮不显示）。
const String kLogUploadEndpoint = '';
const String kLogUploadToken = '';
