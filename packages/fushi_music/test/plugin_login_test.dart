import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

import 'plugin_host_test.dart'
    show buildPlugin, manifest, fakePublicResolve, noRedirectProbe;

/// 登录契约（docs/specs/2026-10-28-music-plugins.md §4.1）：扫码轮询、表单提交、加密凭据、
/// web / appUrl 按权限与网络授权过滤、卸载清凭据。
const String loginJs = r'''
let polls = 0;
module.exports = {
  search() { return { items: [], hasMore: false }; },
  album() {}, stream() {}, lyrics() { return null; },
  async account() {
    const c = await fushi.credentials.get('cookie');
    return c ? { loggedIn: true, name: 'Alice', badge: 'VIP' } : { loggedIn: false };
  },
  async login(a) {
    switch (a.op) {
      case 'methods':
        return { methods: [
          { id: 'qr', type: 'qr', label: '扫码' },
          { id: 'cookie', type: 'form', label: '粘贴 Cookie' },
          { id: 'web', type: 'web', label: '网页登录' },
          { id: 'bogus', type: 'telepathy', label: 'x' },
        ] };
      case 'begin':
        if (a.method === 'qr') {
          return { state: 'pending', session: 'k1', qr: { content: 'https://x/qr?k=k1' },
                   pollMs: 50, appUrl: a.platform === 'android' ? 'orpheus://confirm?k=k1' : undefined };
        }
        if (a.method === 'web') {
          return { state: 'pending', web: { url: 'https://api.example.com/login',
                   cookieUrl: 'https://api.example.com/', doneCookie: 'SID' } };
        }
        if (a.method === 'evil') {
          return { state: 'pending', appUrl: 'file:///etc/passwd',
                   web: { url: 'https://evil.com/', cookieUrl: 'https://evil.com/', doneCookie: 'x' } };
        }
        return { state: 'pending', form: {
          fields: [{ id: 'cookie', label: 'Cookie', secret: true, multiline: true }, { label: 'no id' }],
          actions: [{ id: 'submit', label: '登录', primary: true }] } };
      case 'poll':
        polls++;
        if (a.session !== 'k1') throw new Error('bad session');
        if (polls === 1) return { state: 'pending', session: 'k1', qr: { content: 'https://x/qr?k=k1', scanned: true }, message: '已扫码' };
        await fushi.credentials.set('cookie', 'MUSIC_U=qr');
        return { state: 'done', account: { loggedIn: true, name: 'Alice' } };
      case 'submit':
        if (!a.inputs.cookie) return { state: 'failed', message: 'Cookie 为空' };
        await fushi.credentials.set('cookie', a.inputs.cookie);
        return { state: 'done' };
      case 'logout':
        await fushi.credentials.remove('cookie');
        return null;
    }
  },
};
''';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('fmp-login-'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<(MusicPluginManager, MusicPluginSource)> install({
    List<String> perms = const <String>['network', 'credentials', 'webAuth'],
  }) async {
    final MusicPluginManager m = MusicPluginManager(
      rootDir: root,
      httpClientFactory: HttpClient.new,
      resolver: fakePublicResolve,
      mediaProbe: noRedirectProbe,
      log: (_, _, _) {},
    );
    final Uint8List zip = buildPlugin(
      manifest(
        caps: const <String>[
          'search',
          'album',
          'stream',
          'lyrics',
          'login',
          'account',
        ],
        perms: perms,
      ),
      <String, String>{'main.js': loginJs},
    );
    await m.install(zip, (await m.inspect(zip)).digest);
    return (m, m.source('moe.test.fake'));
  }

  test('扫码：begin → poll（已扫码）→ poll（完成）→ 账号；凭据加密落盘', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    expect((await src.account()).loggedIn, isFalse);
    final List<MusicPluginLoginMethod> methods = await src.loginMethods(
      'windows',
    );
    expect(methods.map((MusicPluginLoginMethod x) => x.id), <String>[
      'qr',
      'cookie',
      'web',
    ], reason: '未知类型的方式丢弃');

    MusicPluginLoginChallenge c = await src.loginBegin('qr', 'windows');
    expect(c.state, MusicPluginLoginState.pending);
    expect(c.qrContent, 'https://x/qr?k=k1');
    expect(c.pollMs, 500, reason: 'pollMs 下限 500');
    expect(c.appUrl, isNull);
    expect(
      (await src.loginBegin('qr', 'android')).appUrl,
      'orpheus://confirm?k=k1',
    );

    c = await src.loginPoll('qr', c.session, 'windows');
    expect(c.qrScanned, isTrue);
    expect(c.message, '已扫码');
    c = await src.loginPoll('qr', c.session, 'windows');
    expect(c.state, MusicPluginLoginState.done);
    expect(c.account?.name, 'Alice');

    final MusicPluginAccount acc = await src.account();
    expect(acc.loggedIn, isTrue);
    expect(acc.badge, 'VIP');
    // 凭据落盘的是密文：明文 Cookie 不出现在凭据目录的任何文件里。
    final Directory vault = Directory('${root.path}/.credentials');
    expect(vault.listSync(), isNotEmpty);
    for (final FileSystemEntity f in vault.listSync(recursive: true)) {
      if (f is File) {
        expect(
          f.readAsBytesSync().toString().contains(
            '77, 85, 83, 73, 67, 95, 85, 61, 113, 114',
          ),
          isFalse,
          reason: f.path,
        );
      }
    }

    await src.logout();
    expect((await src.account()).loggedIn, isFalse);
    await m.dispose();
  });

  test('表单：字段 / 按钮解析，submit 成功与失败', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final MusicPluginLoginChallenge c = await src.loginBegin(
      'cookie',
      'windows',
    );
    expect(c.fields.single.id, 'cookie');
    expect(c.fields.single.secret, isTrue);
    expect(c.fields.single.multiline, isTrue);
    expect(c.actions.single.primary, isTrue);
    expect(
      (await src.loginSubmit(
        'cookie',
        null,
        'windows',
        action: 'submit',
        inputs: <String, String>{'cookie': ''},
      )).state,
      MusicPluginLoginState.failed,
    );
    expect(
      (await src.loginSubmit(
        'cookie',
        null,
        'windows',
        action: 'submit',
        inputs: <String, String>{'cookie': 'MUSIC_U=x'},
      )).state,
      MusicPluginLoginState.done,
    );
    expect((await src.account()).loggedIn, isTrue);
    // 卸载清掉凭据：重装后是未登录。
    await m.uninstall('moe.test.fake');
    await m.dispose();
    final (MusicPluginManager m2, MusicPluginSource src2) = await install();
    expect((await src2.account()).loggedIn, isFalse);
    await m2.dispose();
  });

  test('web 需要 webAuth 且地址在授权内；越权 appUrl 丢弃', () async {
    final (MusicPluginManager m, MusicPluginSource src) = await install();
    final MusicPluginLoginChallenge web = await src.loginBegin(
      'web',
      'windows',
    );
    expect(web.hasWeb, isTrue);
    expect(web.webDoneCookie, 'SID');
    final MusicPluginLoginChallenge evil = await src.loginBegin(
      'evil',
      'android',
    );
    expect(evil.hasWeb, isFalse, reason: '登录页不在网络授权内');
    expect(evil.appUrl, isNull, reason: 'file: scheme 不是官方 App');
    await m.dispose();

    root.deleteSync(recursive: true);
    root.createSync();
    final (MusicPluginManager m2, MusicPluginSource src2) = await install(
      perms: const <String>['network', 'credentials'],
    );
    expect(
      (await src2.loginBegin('web', 'windows')).hasWeb,
      isFalse,
      reason: '没有 webAuth 权限',
    );
    await m2.dispose();
  });
}
