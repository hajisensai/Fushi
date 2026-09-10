import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 宿主 → sidecar：本次调用该源站可用的全部 cookie（BUG-2425）。
///
/// **为什么不用标准的 `Cookie:` 头**（第一版就是那么做的，是错的）：
/// 1. 扁平 `name=value` 串**丢掉 domain / path / secure / hostOnly / 过期时刻**。
///    okhttp 的 jar 把 `secure` 与 `hostOnly` 算进 cookie 身份，丢了这两位注进去
///    的条目就与站点自己写的同名条目并存，`session=旧值; session=新值` 一起发出，
///    取首值的服务端拿到作废的那个。域丢了则只能整组重标到源站 baseUrl 的 host，
///    把作用域平白放宽到父域及其全部子域。
/// 2. 更要命的是它与**传输层**的 `User-Agent` 撞在同一组标准头里：`package:http`
///    底下的 `dart:io` `HttpClient` 默认无条件带 `User-Agent: Dart/x.y (dart:io)`
///    （`http_impl.dart` 的 `userAgent = _getHttpVersion()`），而 sidecar 当时把
///    **收到的任何 UA** 都当成「把这个源的 UA 设成它」，于是每次调用都把源的默认
///    UA 改写成 `Dart/...`——按 UA 拦截的日站因此登录了照样 403。
///
/// 自有头 + 结构化载荷把这两条一起消掉：线格式无损，且传输层的头再也不会被误认
/// 成源的身份。
const String kMihonCookieHeader = 'X-Fushi-Cookies';

/// sidecar → 宿主：本次调用后该源 jar 里的 cookie（会话续期 / 轮转 token）。
///
/// 头名小写：`package:http` 的 `Response.headers` 键一律小写化，直接用小写常量
/// 查表，省掉一层大小写归一。（请求头由我们自己写，大小写不敏感。）
const String kMihonSetCookieHeader = 'x-fushi-set-cookie';

/// 两个方向共用的载荷编解码：**base64(UTF-8 JSON 数组)**。
///
/// 为什么套一层 base64：HTTP 头值只保证 ASCII 且不能含换行，而 cookie 值里出现
/// 非 ASCII、逗号、分号都是合法的（日站的会话 cookie 常带 URL 编码外的原始字节）。
/// 裸放 JSON 会被 NanoHTTPD 与 `package:http` 的头解析在中途截断或按逗号拆成多值
/// ——那种损坏是静默的，只表现为「登录态偶尔失效」。
List<MangaCookie> decodeMihonCookieWire(String raw) {
  try {
    final Object? decoded = jsonDecode(utf8.decode(base64Decode(raw)));
    if (decoded is! List<Object?>) return const <MangaCookie>[];
    return decoded
        .whereType<Map<Object?, Object?>>()
        .map(
          (Map<Object?, Object?> item) =>
              MangaCookie.fromJson(item.cast<String, Object?>()),
        )
        .where((MangaCookie cookie) => cookie.isValid)
        .toList(growable: false);
  } on FormatException {
    // 坏载荷 = 这一轮没有 cookie 更新。宿主手上的旧值继续用，不该因为一个头
    // 解不开就把整次源调用判失败。
    return const <MangaCookie>[];
  }
}

String encodeMihonCookieWire(List<MangaCookie> cookies) => base64Encode(
      utf8.encode(
        jsonEncode(
            cookies.map((MangaCookie cookie) => cookie.toJson()).toList()),
      ),
    );

/// Mihon 扩展的登录态真值（BUG-2425）。
///
/// **为什么必须由宿主持有**：桌面 sidecar 里有三份互不相通的 cookie 存储——
/// okhttp 的 `MemoryCookieJar`、`java.net.InMemoryCookieStore`（`Main.kt` 装的）、
/// 以及 CEF 内部的——三份**全在子进程内存里**，`DesktopMihonRuntime._restart()`
/// （`invalidateExtensions` / `clearSourceData` 都会触发）一来就清空。结果是登录态
/// 在桌面端没有所有者：无处持久，也无从建立，需要登录的源永远锁着。
///
/// 修法不是再加第四份存储，而是**让宿主成为唯一所有者**：真值落在这个文件里，
/// sidecar 的 jar 退化成易失缓存，每次调用由 `DesktopMihonRuntime` 经 `Cookie:`
/// 请求头重新注入（sidecar 的 `DalvikHandler` 早就支持读这个头，只是以前没人发）。
///
/// Android 不用这条路：那边系统级 `CookieManager` 本来就是唯一所有者，
/// `AndroidCookieJar` 直接读它。
///
/// 只存 Mihon 源站的 cookie，设备本地、不进同步/备份。
class MihonCookieJar extends MangaCookieJar {
  MihonCookieJar(super.file, {super.clock});

  MihonCookieJar.lazy(super.resolveFile, {super.clock}) : super.lazy();

  /// 进程级共享实例，落在 Mihon sidecar 数据目录旁的 `cookies.json`。
  ///
  /// 路径与 `AppModel.mihonManager` 传给 sidecar 的 root 一致：那里用的是
  /// `databaseDirectory/mihon`，而 `databaseDirectory` 就是 `AppPaths.supportRoot`
  /// （`app_model.dart` 的 `_databaseDirectory = _appPaths.supportRoot`）。
  static MihonCookieJar get shared =>
      _shared ??= MihonCookieJar.lazy(_sharedFile);
  static MihonCookieJar? _shared;

  /// 测试替换共享实例。
  static set shared(MihonCookieJar? value) => _shared = value;

  static Future<File> _sharedFile() async {
    final Directory supportRoot = await AppPaths.supportRootDirectory();
    return File(p.join(supportRoot.path, 'mihon', 'cookies.json'));
  }
}
