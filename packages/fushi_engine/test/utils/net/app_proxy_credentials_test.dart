// appManualProxyBasicCredentials：HttpClient 的 407 应答钩子与联网搜索自建 CONNECT
// 隧道共用的唯一凭据判据。
import 'package:fushi_engine/utils/net/app_proxy.dart';
import 'package:test/test.dart';

void main() {
  late String Function() mode;
  late String Function() proxy;
  late String Function() user;
  late String Function() pass;

  setUp(() {
    mode = appUserProxyModeReader;
    proxy = appUserProxyReader;
    user = appUserProxyUsernameReader;
    pass = appUserProxyPasswordReader;
    appUserProxyModeReader = () => kProxyModeManual;
    appUserProxyReader = () => 'http://Proxy.Example:7890';
    appUserProxyUsernameReader = () => 'alice';
    appUserProxyPasswordReader = () => 's3cret';
  });
  tearDown(() {
    appUserProxyModeReader = mode;
    appUserProxyReader = proxy;
    appUserProxyUsernameReader = user;
    appUserProxyPasswordReader = pass;
  });

  test('手动模式、问的正是手填代理：给出凭据（主机名不分大小写）', () {
    expect(appManualProxyBasicCredentials('proxy.example', 7890), (
      username: 'alice',
      password: 's3cret',
    ));
  });

  test('别的代理 / 别的端口 / 没填用户名 / 非手动模式：null', () {
    expect(appManualProxyBasicCredentials('other.example', 7890), isNull);
    expect(appManualProxyBasicCredentials('proxy.example', 8080), isNull);
    appUserProxyUsernameReader = () => '';
    expect(appManualProxyBasicCredentials('proxy.example', 7890), isNull);
    appUserProxyUsernameReader = () => 'alice';
    appUserProxyModeReader = () => kProxyModeAuto;
    expect(appManualProxyBasicCredentials('proxy.example', 7890), isNull);
  });
}
