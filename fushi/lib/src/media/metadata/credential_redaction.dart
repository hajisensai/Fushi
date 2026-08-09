/// URL query 凭据脱敏（BUG-1219 审查发现）。
///
/// 为什么必须在**异常构造侧**做，而不是在界面上过滤：`package:http` 的
/// `ClientException.toString()` 是 `'ClientException: $message, uri=$uri'`
/// （`io_client.dart` 在 `SocketException` 时把 `request.url` 整个塞进异常），
/// 而 TMDB 是 key-in-query 的 —— 于是一次 DNS 失败就把
/// `...&api_key=<用户的 key>` 拼进了异常文本。那串文本随后同时流向**三条路**：
///  ① 弹窗失败态（可选中 + 一键复制 → 用户截图/粘贴求助即泄露）；
///  ② `ErrorLogService.log` 存的是 `error.toString()`，零脱敏，并落盘；
///  ③ 日志上传（`log_uploader.dart` 上传前同样不脱敏）。
///
/// 只堵界面等于留着 ②③ 继续漏，所以收口在异常刚被构造出来的地方：抛出去的
/// message 本身就不含凭据，三条路一次修好。
///
/// （`PrefRedactionPolicy` 管的是 `preferences` 表的 key，与本文件无交集，勿混。）
library;

/// 视为凭据的 query 参数名（小写比较）。
///
/// 覆盖本仓真实出站 client 与常见第三方约定。宁可多脱一个也不漏：这里处理的是
/// **错误文本**，多脱一个参数只损失一点排查信息，漏一个就是把用户凭据发出去。
const Set<String> kCredentialQueryParams = <String>{
  'api_key',
  'apikey',
  'key',
  'access_token',
  'accesstoken',
  'token',
  'auth',
  'auth_token',
  'password',
  'passwd',
  'secret',
  'client_secret',
  'signature',
  'sig',
  'jackett_apikey',
  'passkey',
  'authkey',
  'rsskey',
};

/// 脱敏后的占位值（保留参数名，便于排查「是不是带了 key」，但不泄露值本身）。
const String kRedactedPlaceholder = '<redacted>';

/// 把自由文本里所有 `?k=v` / `&k=v` 形式的凭据参数值换成 [kRedactedPlaceholder]。
///
/// 刻意**不做完整 URL 解析**：待处理的是异常 `toString()` 这种自由文本，URL 只是
/// 其中一段（`..., uri=https://host/p?a=1&api_key=XXX`），后面还可能跟别的话。
/// 按 query 分隔符逐段替换对这种嵌入形态最稳，也不会因为 URL 本身不合法而失效。
///
/// 值的终止符取 `&`、空白、以及 `"'<>` 与 `)`：覆盖 `uri=...` 直接接句末、被引号
/// 包住、或被括号包住这几种真实拼法。
String redactCredentialsInText(String text) {
  if (text.isEmpty) return text;
  final RegExp pattern = RegExp(
    r'([?&])([A-Za-z_][A-Za-z0-9_\-]*)=([^&\s"' "'" r'<>)]*)',
  );
  return text.replaceAllMapped(pattern, (Match m) {
    final String sep = m.group(1)!;
    final String name = m.group(2)!;
    final String value = m.group(3)!;
    if (value.isEmpty) return m.group(0)!;
    if (!kCredentialQueryParams.contains(name.toLowerCase())) {
      return m.group(0)!;
    }
    return '$sep$name=$kRedactedPlaceholder';
  });
}
