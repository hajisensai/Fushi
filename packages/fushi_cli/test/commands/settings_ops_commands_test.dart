import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/data_commands.dart';
import 'package:fushi_cli/src/commands/dictionary_commands.dart';
import 'package:fushi_cli/src/commands/settings_commands.dart';
import 'package:fushi_cli/src/commands/video_commands.dart';
import 'package:test/test.dart';

/// 按命令表解析 [args] 并 build 出请求（与 CLI 主循环同样的 parser 装配）。
CtlRequestSpec build(String group, String command, List<String> args) {
  final List<CtlCommandGroup> all = <CtlCommandGroup>[
    ...settingsCommandGroups,
    ...dataCommandGroups,
    ...dictionaryCommandGroups,
    ...videoCommandGroups,
  ];
  final CtlCommandSpec spec = all
      .firstWhere((CtlCommandGroup g) => g.name == group)
      .find(command)!;
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

String render(String group, String command, Object? data) {
  final List<CtlCommandGroup> all = <CtlCommandGroup>[
    ...settingsCommandGroups,
    ...dataCommandGroups,
  ];
  return all
      .firstWhere((CtlCommandGroup g) => g.name == group)
      .find(command)!
      .render!(data);
}

void main() {
  group('update', () {
    test('check / download / cancel 走对应动作行', () {
      expect(
        build('update', 'check', <String>[]).path,
        '/api/admin/settings/system.check_update_now/run',
      );
      expect(
        build('update', 'download', <String>[]).path,
        '/api/admin/settings/system.update.download/run',
      );
      expect(
        build('update', 'cancel', <String>[]).path,
        '/api/admin/settings/system.update.cancel/run',
      );
    });

    test('install 必须 --yes，带 confirm', () {
      expect(
        () => build('update', 'install', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec r = build('update', 'install', <String>['--yes']);
      expect(r.path, '/api/admin/settings/system.update.install/run');
      expect(r.body, <String, Object?>{'confirm': true});
    });

    test('status 列出 update 族任务', () {
      final CtlRequestSpec r = build('update', 'status', <String>[]);
      expect(r.path, '/api/admin/tasks');
      expect(r.query, <String, String>{'kind': 'update'});
    });

    test('check 渲染出版本与更新说明', () {
      final String out = render('update', 'check', <String, Object?>{
        'result': <String, Object?>{
          'currentVersion': '1.0.0',
          'channel': 'stable',
          'updateAvailable': true,
          'version': '1.1.0',
          'installable': true,
          'releaseNotes': '- 修了个 bug',
        },
      });
      expect(out, contains('1.1.0'));
      expect(out, contains('修了个 bug'));
      expect(out, contains('update download'));
    });
  });

  group('task', () {
    test('get --wait 带等待秒数，越界拒绝', () {
      final CtlRequestSpec r = build('task', 'get', <String>[
        'update-download-1',
        '--wait',
        '60',
      ]);
      expect(r.path, '/api/admin/tasks/update-download-1');
      expect(r.query, <String, String>{'wait': '60'});
      expect(
        () => build('task', 'get', <String>['x', '--wait', '601']),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('cancel / ls', () {
      expect(
        build('task', 'cancel', <String>['a b']).path,
        '/api/admin/tasks/a%20b/cancel',
      );
      expect(
        build('task', 'ls', <String>['--kind', 'plex-sign-in']).query,
        <String, String>{'kind': 'plex-sign-in'},
      );
    });

    test('运行中的任务渲染出等待 / 取消提示', () {
      final String out = render('task', 'get', <String, Object?>{
        'id': 't1',
        'kind': 'external-reader-import',
        'status': 'running',
        'progress': 40.0,
        'cancellable': true,
      });
      expect(out, contains('40.0%'));
      expect(out, contains('task cancel t1'));
    });
  });

  group('audiosrc', () {
    test('add --url / --path / --fushi-remote 恰好一个', () {
      final CtlRequestSpec r = build('audiosrc', 'add', <String>[
        '--url',
        'https://a.example/?q={term}',
        '--label',
        'A',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/settings/lookup.audio_sources.items/items');
      expect((r.body!['args']! as Map)['kind'], 'remote');
      expect(
        () => build('audiosrc', 'add', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('audiosrc', 'add', <String>[
          '--url',
          'https://a/{term}',
          '--fushi-remote',
        ]),
        throwsA(isA<CtlUsageError>()),
      );
    });

    test('add --path 转绝对路径', () {
      final CtlRequestSpec r = build('audiosrc', 'add', <String>[
        '--path',
        'android.db',
        '--reference',
      ]);
      final Map<Object?, Object?> args = r.body!['args']! as Map;
      expect(args['kind'], 'local');
      expect(args['reference'], 'true');
      expect(File(args['path']! as String).isAbsolute, isTrue);
    });

    test('set 启停 / 挪位置，rm / reset 要 --yes', () {
      final CtlRequestSpec r = build('audiosrc', 'set', <String>[
        'remote:https://a/{term}',
        '--disable',
        '--position',
        '2',
      ]);
      expect(r.method, 'PUT');
      expect(
        r.path,
        '/api/admin/settings/lookup.audio_sources.items/items/'
        '${Uri.encodeComponent('remote:https://a/{term}')}',
      );
      expect(r.body, <String, Object?>{
        'args': <String, String>{'position': '2', 'enabled': 'false'},
      });
      expect(
        () => build('audiosrc', 'rm', <String>['fushi_remote']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('audiosrc', 'reset', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        build('audiosrc', 'reset', <String>['--yes']).body,
        <String, Object?>{'confirm': true},
      );
    });
  });

  group('sync compare', () {
    test('compare 走 sync.compare，compare-apply 要 --yes 并把 --item 编成 JSON', () {
      expect(
        build('sync', 'compare', <String>[]).path,
        '/api/admin/settings/sync.compare/run',
      );
      expect(
        () => build('sync', 'compare-apply', <String>[]),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec r = build('sync', 'compare-apply', <String>[
        '--yes',
        '--keep',
        'skip',
        '--item',
        'book=a=local',
      ]);
      expect(r.path, '/api/admin/settings/sync.compare_apply/run');
      expect(r.body!['confirm'], isTrue);
      final Map<Object?, Object?> args = r.body!['args']! as Map;
      expect(args['keep'], 'skip');
      // id 里可以有 '='：按最后一个 '=' 切。
      expect(jsonDecode(args['items']! as String), <String, Object?>{
        'book=a': 'local',
      });
    });
  });

  group('plex-login', () {
    test('带 open / timeout，渲染出授权链接与 PIN', () {
      final CtlRequestSpec r = build('mediaserver', 'plex-login', <String>[
        '--open',
        '--timeout',
        '300',
      ]);
      expect(
        r.path,
        '/api/admin/settings/services.media_server.plex.sign_in/run',
      );
      expect(r.body, <String, Object?>{
        'args': <String, String>{'open': 'true', 'timeout': '300'},
      });
      final String out = render('mediaserver', 'plex-login', <String, Object?>{
        'result': <String, Object?>{
          'id': 'plex-sign-in-1',
          'detail': <String, Object?>{
            'authUrl': 'https://app.plex.tv/auth#?code=ABCD',
            'pin': 'ABCD',
          },
        },
      });
      expect(out, contains('https://app.plex.tv/auth#?code=ABCD'));
      expect(out, contains('PIN：ABCD'));
      expect(out, contains('task get plex-sign-in-1'));
    });
  });

  group('anki 同步客户端', () {
    test('sync-login：密码只经环境变量 / stdin，进 secrets 不进 args', () {
      final String name = Platform.environment.containsKey('PATH')
          ? 'PATH'
          : Platform.environment.keys.first;
      final CtlRequestSpec r = build('anki', 'sync-login', <String>[
        'alice',
        '--server',
        'https://sync.example',
        '--password-from-env',
        name,
      ]);
      expect(
        r.path,
        '/api/admin/settings/card_creation.anki.sync_client.sign_in/run',
      );
      expect(r.body!['args'], <String, String>{
        'username': 'alice',
        'server': 'https://sync.example',
      });
      expect(r.body!['secrets'], <String, String>{
        'password': Platform.environment[name]!,
      });
      expect(r.body!['secretSource'], 'env');
    });

    test('sync-login：没给密码来源 / AnkiWeb 未确认都拒绝', () {
      expect(
        () => build('anki', 'sync-login', <String>['alice', '--server', 'x']),
        throwsA(isA<CtlUsageError>()),
      );
      expect(
        () => build('anki', 'sync-login', <String>[
          'alice',
          '--password-from-env',
          'PATH',
        ]),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec web = build('anki', 'sync-login', <String>[
        'alice',
        '--password-from-env',
        'PATH',
        '--accept-ankiweb',
      ]);
      expect((web.body!['args']! as Map)['accept_ankiweb'], 'true');
    });

    test('sync-logout --discard 必须 --yes', () {
      expect(
        build('anki', 'sync-logout', <String>[]).path,
        '/api/admin/settings/card_creation.anki.sync_client.sign_out/run',
      );
      expect(
        () => build('anki', 'sync-logout', <String>['--discard']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec r = build('anki', 'sync-logout', <String>[
        '--discard',
        '--yes',
      ]);
      expect(
        r.path,
        '/api/admin/settings/card_creation.anki.sync_client.sign_out_discard/run',
      );
      expect(r.body, <String, Object?>{'confirm': true});
    });

    test('sync-use on 必须 --yes 并走带确认的 enable 动作；off 直接写开关', () {
      // 与设置页启用前的警告确认框同一道闸。
      expect(
        () => build('anki', 'sync-use', <String>['on']),
        throwsA(isA<CtlUsageError>()),
      );
      final CtlRequestSpec on = build('anki', 'sync-use', <String>[
        'on',
        '--yes',
      ]);
      expect(on.method, 'POST');
      expect(
        on.path,
        '/api/admin/settings/card_creation.anki.sync_client.enable/run',
      );
      expect(on.body, <String, Object?>{'confirm': true});
      final CtlRequestSpec r = build('anki', 'sync-use', <String>['off']);
      expect(r.method, 'PUT');
      expect(
        r.path,
        '/api/admin/settings/card_creation.anki.sync_client.enabled',
      );
      expect(r.body!['value'], 'false');
      expect(
        () => build('anki', 'sync-use', <String>['maybe']),
        throwsA(isA<CtlUsageError>()),
      );
    });
  });

  group('video 设置操作', () {
    test('sub-position 参数映射到拖动入口', () {
      final CtlRequestSpec r = build('video', 'sub-position', <String>[
        '--position',
        '120',
        '--anchor',
        'top',
        '--secondary-position',
        '40',
      ]);
      expect(r.path, '/api/admin/settings/video.subtitle.drag_adjust/run');
      expect(r.body, <String, Object?>{
        'args': <String, String>{
          'position': '120',
          'anchor': 'top',
          'secondary_position': '40',
        },
      });
      expect(
        build('video', 'sub-position', <String>[]).body,
        <String, Object?>{},
      );
    });

    test('shader-tier：不给 = 读，给档位 = 写', () {
      final CtlRequestSpec read = build('video', 'shader-tier', <String>[]);
      expect(read.method, 'GET');
      expect(read.path, '/api/admin/settings/video.player.shader_tier');
      final CtlRequestSpec write = build('video', 'shader-tier', <String>[
        'high',
      ]);
      expect(write.method, 'PUT');
      expect(write.body!['value'], 'high');
    });

    test('shader-discover / mpv-dir', () {
      final CtlRequestSpec r = build('video', 'shader-discover', <String>[
        '--import',
        'all',
      ]);
      expect(r.path, '/api/admin/settings/video.player.shader_discover/run');
      expect(r.body, <String, Object?>{
        'args': <String, String>{'import': 'all'},
      });
      expect(build('video', 'mpv-dir', <String>[]).method, 'GET');
      expect(build('video', 'mpv-dir', <String>['']).body!['value'], '');
    });
  });
}
