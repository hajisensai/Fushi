// 入库默认值（空，保证任何 clone/worktree 都能直接编译；端点为空时日志页的
// 「上传」按钮自动隐藏，故 fresh clone 不配此文件也能正常构建）。
//
// 本机要启用日志上传时：填真值后执行一次——
//   git update-index --skip-worktree hibiki/lib/src/utils/misc/log_upload_secret.dart
// 真值只留本地、不显示 dirty、永不提交。来源见 server/cf-worker/DEPLOYMENT_SECRETS.local.md：
//   kLogUploadEndpoint = 'https://logs.<你的域名>/api/logs'
//   kLogUploadToken    = 接收端的 UPLOAD_TOKEN
const String kLogUploadEndpoint = '';
const String kLogUploadToken = '';
