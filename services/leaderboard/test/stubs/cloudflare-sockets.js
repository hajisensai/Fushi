// 测试环境里 `cloudflare:sockets` 的替身（Node 没有这个内建模块）。真正的连接在测试里经 env.SMTP_CONNECT 注入。
export function connect() {
  throw new Error('cloudflare:sockets is not available in tests; inject env.SMTP_CONNECT');
}
