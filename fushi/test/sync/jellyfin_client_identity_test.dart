// AL8qJr6yr-：某 Emby 服务器添加失败而 SenPlayer / Hills / Yamby 都能用。线索：
// 认证头一直写死旧品牌 `Client="Hibiki", Device="Hibiki", Version="1.0"`；且
// 添加失败时日志里没有任何请求轨迹，下一次反馈照样无从定位。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/jellyfin_settings_widget.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/media_server/media_server_client_identity.dart';
import 'package:fushi_platform/fushi_platform.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _DeviceInfo implements PlatformDeviceInfoService {
  _DeviceInfo(this._model, {this.throws = false});

  final String? _model;
  final bool throws;

  @override
  Future<String?> get deviceModel async {
    if (throws) throw StateError('device_info unavailable');
    return _model;
  }

  @override
  Future<String?> get manufacturer async => null;

  @override
  Future<int?> get sdkVersion async => null;
}

const String _password = 'S3cret-pw!';
const String _token = 'tok-abcdef123456';

void main() {
  late FushiDatabase db;
  late SyncRepository repo;
  late MediaServerClientIdentity saved;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    saved = mediaServerClientIdentity;
    await ErrorLogService.instance.clear();
  });

  tearDown(() async {
    mediaServerClientIdentity = saved;
    await db.close();
  });

  group('认证头报本应用的真实身份', () {
    test('Client = 产品名、Device = 本机设备名、Version = 应用版本；不再是 Hibiki', () {
      final String header = JellyfinApi.authHeaderFor(
        _token,
        'dev-42',
        const MediaServerClientIdentity(
          deviceName: 'DESKTOP-ABC',
          version: '3.0.1',
        ),
      );
      expect(header, contains('Client="Fushi"'));
      expect(header, contains('Device="DESKTOP-ABC"'));
      expect(header, contains('Version="3.0.1"'));
      expect(header, contains('DeviceId="dev-42"'));
      expect(header, contains('Token="$_token"'));
      expect(header, isNot(contains('Hibiki')));
    });

    test('缺省读进程级身份（主进程启动时装配）', () {
      mediaServerClientIdentity = const MediaServerClientIdentity(
        deviceName: 'Pixel 8',
        version: '9.9.9',
      );
      final String header = JellyfinApi.authHeaderFor();
      expect(header, contains('Device="Pixel 8"'));
      expect(header, contains('Version="9.9.9"'));
      expect(header, isNot(contains('Token=')));
    });

    test('登录请求两个认证头名都带新身份', () async {
      mediaServerClientIdentity = const MediaServerClientIdentity(
        deviceName: 'MacBook',
        version: '3.0.1',
      );
      final List<http.Request> seen = <http.Request>[];
      await signInJellyfinServer(
        repo,
        url: 'http://nas:8096',
        username: 'u',
        password: _password,
        httpClientFactory: () => MockClient((http.Request req) async {
          seen.add(req);
          if (req.url.path == '/Users/AuthenticateByName') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'AccessToken': _token,
                'User': <String, Object?>{'Id': 'u1'},
              }),
              200,
            );
          }
          return http.Response(jsonEncode(<String, Object?>{}), 200);
        }),
      );
      final http.Request login = seen.lastWhere(
        (http.Request r) => r.url.path == '/Users/AuthenticateByName',
      );
      for (final String name in <String>[
        'authorization',
        'x-emby-authorization',
      ]) {
        expect(login.headers[name], contains('Client="Fushi"'));
        expect(login.headers[name], contains('Device="MacBook"'));
      }
      expect(ErrorLogService.instance.entries, isEmpty, reason: '成功不记失败轨迹');
    });

    // 部分公益服的 Cloudflare 前置按 UA 拦「Dart」子串：不显式设 UA 时
    // package:http 会自报 `Dart/<SDK> (dart:io)`，整站回裸 404（连公开端点
    // 和登录都进不去），而 SenPlayer / Hills / Yamby 因自报 UA 正常。
    test('每个请求自报 User-Agent：产品名/版本，不含 Dart', () async {
      mediaServerClientIdentity = const MediaServerClientIdentity(
        deviceName: 'MacBook',
        version: '3.0.1',
      );
      expect(JellyfinApi.userAgentFor(), 'Fushi/3.0.1');
      expect(JellyfinApi.userAgentFor(), isNot(contains('Dart')));

      final List<http.Request> seen = <http.Request>[];
      await signInJellyfinServer(
        repo,
        url: 'http://nas:8096',
        username: 'u',
        password: _password,
        httpClientFactory: () => MockClient((http.Request req) async {
          seen.add(req);
          if (req.url.path == '/Users/AuthenticateByName') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'AccessToken': _token,
                'User': <String, Object?>{'Id': 'u1'},
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{'ServerName': 'N'}),
            200,
          );
        }),
      );
      expect(seen, isNotEmpty);
      for (final http.Request req in seen) {
        expect(
          req.headers['user-agent'],
          'Fushi/3.0.1',
          reason: '${req.method} ${req.url.path} 缺自报 UA',
        );
      }
    });
  });

  group('身份解析', () {
    test('设备名取平台设备信息；无意义值 / 插件抛错回落产品名', () async {
      expect(
        (await resolveMediaServerClientIdentity(
          _DeviceInfo('DESKTOP-ABC'),
          version: '3.0.1',
        )).deviceName,
        'DESKTOP-ABC',
      );
      expect(
        (await resolveMediaServerClientIdentity(
          _DeviceInfo('localhost'),
          version: '3.0.1',
        )).deviceName,
        kMediaServerClientProduct,
      );
      expect(
        (await resolveMediaServerClientIdentity(
          _DeviceInfo(null, throws: true),
          version: '3.0.1',
        )).deviceName,
        kMediaServerClientProduct,
      );
    });

    test('头值收成可打印 ASCII、去引号与反斜杠（中文主机名会让 HttpHeaders 抛）', () async {
      expect(
        sanitizeMediaServerHeaderValue('My "PC"\\x', fallback: 'F'),
        'My PCx',
      );
      expect(sanitizeMediaServerHeaderValue('客厅电脑', fallback: 'F'), 'F');
      expect(
        (await resolveMediaServerClientIdentity(
          _DeviceInfo('张三的 iPad'),
          version: '3.0.1+1360',
        )).deviceName,
        'iPad',
      );
    });
  });

  group('添加服务器失败：请求轨迹进错误日志（不含凭据）', () {
    test('公开端点与登录全 404：日志列出每条请求的路径与状态码', () async {
      await expectLater(
        signInJellyfinServer(
          repo,
          url: 'https://emby.example.com',
          username: 'u',
          password: _password,
          httpClientFactory: () => MockClient(
            (http.Request req) async => http.Response(
              '',
              404,
              headers: <String, String>{
                'content-type': 'text/html',
                'server': 'cloudflare',
              },
            ),
          ),
        ),
        throwsA(isA<JellyfinConnectFailure>()),
      );
      final ErrorLogEntry entry = ErrorLogService.instance.entries.single;
      expect(entry.source, 'JellyfinConnect.signIn');
      final String text = entry.error;
      for (final String line in <String>[
        'GET /System/Info/Public → 404 [text/html] [server: cloudflare]',
        'GET /emby/System/Info/Public → 404',
        'GET /System/Ping → 404',
        'GET /emby/System/Ping → 404',
        'POST /Users/AuthenticateByName → 404',
        'POST /emby/Users/AuthenticateByName → 404',
      ]) {
        expect(text, contains(line));
      }
      expect(text, contains('Client="Fushi"'));
      expect(text, contains('user-agent: Fushi/'), reason: 'UA 也进轨迹（BUG-3855）');
      expect(text, isNot(contains(_password)));
      expect(text, isNot(contains('emby.example.com')), reason: '不记主机名');
    });

    test('登录 401：记认证响应码，不记密码 / 令牌', () async {
      await expectLater(
        signInJellyfinServer(
          repo,
          url: 'http://nas:8096',
          username: 'u',
          password: _password,
          httpClientFactory: () => MockClient((http.Request req) async {
            if (req.url.path == '/Users/AuthenticateByName') {
              return http.Response('Invalid username or password', 401);
            }
            return http.Response(
              jsonEncode(<String, Object?>{'ServerName': 'N'}),
              200,
            );
          }),
        ),
        throwsA(isA<JellyfinApiException>()),
      );
      final String text = ErrorLogService.instance.entries.single.error;
      expect(text, contains('GET /System/Info/Public → 200'));
      expect(text, contains('POST /Users/AuthenticateByName → 401'));
      expect(text, isNot(contains(_password)));
    });

    test('输入错误（地址为空）不是连接问题，不记', () async {
      await expectLater(
        signInJellyfinServer(repo, url: ' ', username: 'u', password: 'p'),
        throwsArgumentError,
      );
      expect(ErrorLogService.instance.entries, isEmpty);
    });
  });
}
