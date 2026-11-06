// 反馈 / 闪退报告上传前的日志脱敏。
//
// 错误日志与调试日志是给本机「设置 › 诊断」看的原文，里面会混进本机用户名（家目录
// 路径）、媒体服务器 / 排行榜等的令牌、Authorization / Cookie 头、邮箱地址。它们一旦
// 随反馈离开设备就收不回来，所以在**唯一的汇总点** `collectFeedbackLogText` 统一过一遍
// [redactFeedbackLog]——手动反馈和闪退自动报告都走那里。
//
// 只遮会泄露身份 / 凭据的片段，其余原样保留（排查要看的异常、栈、模块名不受影响）。
// 宁可多遮：请求头一类的值遮到行尾。

/// 遮蔽后的占位符。
const String kFeedbackRedactedMark = '***';

/// 家目录换成的占位符。
const String kFeedbackHomeMark = '~';

/// 视为凭据的 URL 查询参数名（大小写不敏感）。
const List<String> kFeedbackSecretQueryParams = <String>[
  'token',
  'api_key',
  'apikey',
  'access_token',
  'X-Emby-Token',
  'X-Plex-Token',
  'password',
  'passwd',
  'sig',
  'signature',
  'key',
];

/// 值整段视为凭据的请求头名（大小写不敏感），`Name: value` / `Name=value` /
/// `"Name": "value"` 都认。
const List<String> kFeedbackSecretHeaders = <String>[
  'Proxy-Authorization',
  'X-Emby-Authorization',
  'Authorization',
  'Set-Cookie',
  'Cookie',
  'X-Emby-Token',
  'X-Plex-Token',
  'X-MediaBrowser-Token',
];

// 路径里一段名字允许的字符（不含分隔符、空白、引号与 Windows 非法字符）。
const String _seg = r'''[^\\/\s"'<>:|*?]''';

// Windows 家目录：`C:\Users\<name>`、`C:/Users/<name>`、JSON 转义后的 `C:\\Users\\<name>`。
// 用户名可以带空格（`C:\Users\John Doe\…`）：带空格的形式只在后面紧跟分隔符时才认，
// 免得把路径后面的正文吞掉。
final RegExp _windowsHome = RegExp(
  r'(?<![A-Za-z0-9_])[A-Za-z]:(?:\\|/)+Users(?:\\|/)+'
  '(?:$_seg+(?: $_seg+)+(?=\\\\|/)|$_seg+)',
  caseSensitive: false,
);

// macOS `/Users/<name>`、Linux `/home/<name>`。前面紧挨字母数字 / `.` / `-` 的是 URL 路径
// （如 Jellyfin 的 `http://host:8096/Users/<id>/Items`），不当家目录。`file:///Users/x`
// 照样遮。
final RegExp _posixHome = RegExp(
  r'(?<![A-Za-z0-9_.\-])/(?:Users|home)/'
  '$_seg+',
);

// URL 里的 `user:pass@host` 凭据。
final RegExp _urlUserInfo = RegExp(r'''(://)[^/\s:@"'<>]+:[^/\s@"'<>]+@''');

final RegExp _secretQuery = RegExp(
  '([?&;](?:${kFeedbackSecretQueryParams.map(RegExp.escape).join('|')})=)'
  r'''[^&#\s"'<>]+''',
  caseSensitive: false,
);

final RegExp _secretHeader = RegExp(
  // 前面是 `?` / `&` / `;` 的是 URL 查询参数（如 `?X-Plex-Token=`），交给 [_secretQuery]
  // 只遮参数值，不遮到行尾。
  '(?<![A-Za-z0-9_\\-?&;])((?:${kFeedbackSecretHeaders.map(RegExp.escape).join('|')})'
  r'''["']?\s*[:=]\s*)[^\r\n]+''',
  caseSensitive: false,
);

// 令牌至少 8 个字符：免得把正文里的「basic auth」之类当成凭据。
final RegExp _bearer = RegExp(
  r'\b(Bearer|Basic)\s+[A-Za-z0-9\-._~+/]{8,}=*',
  caseSensitive: false,
);

final RegExp _email = RegExp(
  r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}',
);

/// 把日志文本里的家目录、凭据与邮箱遮掉，返回可上传的文本。纯函数。
///
/// 顺序有讲究：先遮 URL 凭据与请求头（它们的值里可能含 `@` / 路径），再遮查询参数、
/// Bearer / Basic 令牌、邮箱，最后换家目录。
String redactFeedbackLog(String text) {
  String out = text;
  out = out.replaceAllMapped(
    _urlUserInfo,
    (Match m) => '${m[1]}$kFeedbackRedactedMark:$kFeedbackRedactedMark@',
  );
  out = out.replaceAllMapped(
    _secretHeader,
    (Match m) => '${m[1]}$kFeedbackRedactedMark',
  );
  out = out.replaceAllMapped(
    _secretQuery,
    (Match m) => '${m[1]}$kFeedbackRedactedMark',
  );
  out = out.replaceAllMapped(
    _bearer,
    (Match m) => '${m[1]} $kFeedbackRedactedMark',
  );
  out = out.replaceAll(_email, '$kFeedbackRedactedMark@$kFeedbackRedactedMark');
  out = out.replaceAll(_windowsHome, kFeedbackHomeMark);
  out = out.replaceAll(_posixHome, kFeedbackHomeMark);
  return out;
}
