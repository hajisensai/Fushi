import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_cli/src/commands/data_commands.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 按命令表解析 [args]（与 `ctl_cli.dart` 的解析同形：每条命令一个独立的
/// ArgParser + 该命令自己的 configure），返回 build 出的请求。
CtlRequestSpec build(String group, String command, List<String> args) {
  final CtlCommandGroup g = dataCommandGroups.firstWhere(
    (CtlCommandGroup g) => g.name == group,
  );
  final CtlCommandSpec spec = g.find(command)!;
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('命令组名与命令名都不重复，且都有 summary', () {
    final Set<String> groups = <String>{};
    for (final CtlCommandGroup g in dataCommandGroups) {
      expect(groups.add(g.name), isTrue, reason: g.name);
      final Set<String> names = <String>{};
      for (final CtlCommandSpec s in g.commands) {
        expect(names.add(s.name), isTrue, reason: '${g.name} ${s.name}');
        expect(s.summary, isNotEmpty);
      }
    }
    expect(groups, <String>{
      'backup',
      'sync',
      'dl',
      'mediaserver',
      'peer',
      'storage',
    });
  });

  group('backup', () {
    test('ls 缺省当前目录、给了目录转绝对路径', () {
      final CtlRequestSpec def = build('backup', 'ls', <String>[]);
      expect(def.method, 'GET');
      expect(def.path, '/api/admin/backups');
      expect(def.query, <String, String>{'dir': p.normalize(p.current)});
      final CtlRequestSpec rel = build('backup', 'ls', <String>['out']);
      expect(rel.query!['dir'], p.normalize(p.absolute('out')));
    });

    test('info 要文件参数', () {
      final CtlRequestSpec r = build('backup', 'info', <String>['a.zip']);
      expect(r.path, '/api/admin/backups/info');
      expect(r.query!['path'], p.normalize(p.absolute('a.zip')));
      expect(() => build('backup', 'info', <String>[]), usageError());
    });

    test('create 缺省输出到当前目录，-o 与分类原样带上', () {
      final CtlRequestSpec def = build('backup', 'create', <String>[]);
      expect(def.method, 'POST');
      expect(def.path, '/api/admin/backups');
      expect(def.body, <String, Object?>{'output': p.normalize(p.current)});

      final CtlRequestSpec r = build('backup', 'create', <String>[
        '-o',
        'x.zip',
        '--category',
        'books,dictionary',
        '--category',
        'fonts',
      ]);
      expect(r.body!['output'], p.normalize(p.absolute('x.zip')));
      expect(r.body!['categories'], <String>['books', 'dictionary', 'fonts']);

      final CtlRequestSpec all = build('backup', 'create', <String>['--all']);
      expect(all.body!['all'], isTrue);
      expect(
        () =>
            build('backup', 'create', <String>['--all', '--category', 'books']),
        usageError(),
      );
    });

    test('restore 必须 --yes，并带 confirm', () {
      expect(() => build('backup', 'restore', <String>['b.zip']), usageError());
      expect(() => build('backup', 'restore', <String>['--yes']), usageError());
      final CtlRequestSpec r = build('backup', 'restore', <String>[
        'b.zip',
        '--yes',
      ]);
      expect(r.method, 'POST');
      expect(r.path, '/api/admin/backups/restore');
      expect(r.body, <String, Object?>{
        'path': p.normalize(p.absolute('b.zip')),
        'confirm': true,
      });
    });

    test('restore --merge / --replace 带模式与分类，仍要 --yes', () {
      expect(
        () => build('backup', 'restore', <String>['b.zip', '--merge']),
        usageError(),
      );
      final CtlRequestSpec m = build('backup', 'restore', <String>[
        'b.zip',
        '--merge',
        '--category',
        'books,fonts',
        '-y',
      ]);
      expect(m.body, <String, Object?>{
        'path': p.normalize(p.absolute('b.zip')),
        'confirm': true,
        'mode': 'merge',
        'categories': <String>['books', 'fonts'],
      });
      final CtlRequestSpec r = build('backup', 'restore', <String>[
        'b.zip',
        '--replace',
        '--import-settings',
        '--yes',
      ]);
      expect(r.body!['mode'], 'replace');
      expect(r.body!['importSettings'], isTrue);
    });

    test('restore 选项组合错误', () {
      expect(
        () => build('backup', 'restore', <String>[
          'b.zip',
          '--merge',
          '--replace',
          '-y',
        ]),
        usageError(),
      );
      expect(
        () => build('backup', 'restore', <String>[
          'b.zip',
          '--category',
          'books',
          '-y',
        ]),
        usageError(),
      );
      expect(
        () => build('backup', 'restore', <String>[
          'b.zip',
          '--merge',
          '--import-settings',
          '-y',
        ]),
        usageError(),
      );
    });
  });

  group('sync', () {
    test('ls / run', () {
      final CtlRequestSpec ls = build('sync', 'ls', <String>[]);
      expect((ls.method, ls.path), ('GET', '/api/admin/sync'));
      final CtlRequestSpec run = build('sync', 'run', <String>[]);
      expect((run.method, run.path), ('POST', '/api/admin/sync/run'));
      expect(run.body, isEmpty);
      expect(build('sync', 'run', <String>['--wait']).body, <String, Object?>{
        'wait': true,
      });
    });

    test('run 指定通道：位置参数 / 逗号分隔、去重，未知名用法错误', () {
      expect(
        build('sync', 'run', <String>['interconnect', '--wait']).body,
        <String, Object?>{
          'channels': <String>['interconnect'],
          'wait': true,
        },
      );
      expect(
        build('sync', 'run', <String>['cloud,interconnect', 'cloud']).body,
        <String, Object?>{
          'channels': <String>['cloud', 'interconnect'],
        },
      );
      expect(() => build('sync', 'run', <String>['webDav']), usageError());
    });
  });

  group('dl', () {
    test('ls / get', () {
      final CtlRequestSpec ls = build('dl', 'ls', <String>[]);
      expect((ls.method, ls.path), ('GET', '/api/admin/downloads'));
      final CtlRequestSpec get = build('dl', 'get', <String>['j/1']);
      expect(get.path, '/api/admin/downloads/j%2F1');
      expect(() => build('dl', 'get', <String>[]), usageError());
    });

    test('add 磁链原样、种子转绝对路径、URL 原样交给 app 判', () {
      const String magnet = 'magnet:?xt=urn:btih:abc&dn=Foo';
      final CtlRequestSpec m = build('dl', 'add', <String>[
        magnet,
        '--title',
        'T',
        '--kind',
        'tv',
      ]);
      expect((m.method, m.path), ('POST', '/api/admin/downloads'));
      expect(m.body, <String, Object?>{
        'target': magnet,
        'title': 'T',
        'mediaKind': 'tv',
      });
      final CtlRequestSpec t = build('dl', 'add', <String>['a.torrent']);
      expect(t.body, <String, Object?>{
        'target': p.normalize(p.absolute('a.torrent')),
        'mediaKind': 'movie',
      });
      final CtlRequestSpec u = build('dl', 'add', <String>[
        'https://x/a.epub',
        '--kind',
        'novel',
      ]);
      expect(u.body, <String, Object?>{
        'target': 'https://x/a.epub',
        'mediaKind': 'novel',
      });
      // 直链必须给内容类型；磁链 / 种子不收直链的类型。
      expect(
        () => build('dl', 'add', <String>['https://x/a.epub']),
        usageError(),
      );
      expect(
        () => build('dl', 'add', <String>['https://x/a.epub', '--kind', 'tv']),
        usageError(),
      );
      expect(
        () => build('dl', 'add', <String>[magnet, '--kind', 'novel']),
        usageError(),
      );
      expect(() => build('dl', 'add', <String>[]), usageError());
      expect(
        () => build('dl', 'add', <String>[magnet, '--kind', 'anime']),
        throwsA(isA<ArgParserException>()),
      );
    });

    test('cancel / retry', () {
      final CtlRequestSpec c = build('dl', 'cancel', <String>['j1']);
      expect((c.method, c.path), ('POST', '/api/admin/downloads/j1/cancel'));
      final CtlRequestSpec r = build('dl', 'retry', <String>['j1']);
      expect((r.method, r.path), ('POST', '/api/admin/downloads/j1/retry'));
    });

    test('rm 必须 --yes；--delete-files 透传', () {
      expect(() => build('dl', 'rm', <String>['j1']), usageError());
      final CtlRequestSpec r = build('dl', 'rm', <String>['j1', '--yes']);
      expect((r.method, r.path), ('DELETE', '/api/admin/downloads/j1'));
      expect(r.query, <String, String>{'confirm': 'true'});
      final CtlRequestSpec f = build('dl', 'rm', <String>[
        'j1',
        '-y',
        '--delete-files',
      ]);
      expect(f.query, <String, String>{
        'confirm': 'true',
        'deleteFiles': 'true',
      });
    });
  });

  group('mediaserver', () {
    test('ls', () {
      final CtlRequestSpec r = build('mediaserver', 'ls', <String>[]);
      expect((r.method, r.path), ('GET', '/api/admin/media-servers'));
    });

    test('browse：无 parent 列库，有 parent 带分页', () {
      final CtlRequestSpec libs = build('mediaserver', 'browse', <String>['1']);
      expect(libs.path, '/api/admin/media-servers/1/items');
      expect(libs.query, isEmpty);
      final CtlRequestSpec kids = build('mediaserver', 'browse', <String>[
        'jellyfin:http://h/u',
        'abc',
        '--start',
        '50',
        '--limit',
        '25',
      ]);
      expect(
        kids.path,
        '/api/admin/media-servers/jellyfin%3Ahttp%3A%2F%2Fh%2Fu/items',
      );
      expect(kids.query, <String, String>{
        'parent': 'abc',
        'start': '50',
        'limit': '25',
      });
      expect(() => build('mediaserver', 'browse', <String>[]), usageError());
      expect(
        () => build('mediaserver', 'browse', <String>['1', '--start', 'x']),
        usageError(),
      );
    });

    test('search 把剩余参数拼成查询词', () {
      final CtlRequestSpec r = build('mediaserver', 'search', <String>[
        '2',
        'spy',
        'family',
      ]);
      expect(r.path, '/api/admin/media-servers/2/search');
      expect(r.query, <String, String>{'q': 'spy family'});
      expect(() => build('mediaserver', 'search', <String>['2']), usageError());
    });
  });

  group('peer', () {
    test('ls', () {
      final CtlRequestSpec r = build('peer', 'ls', <String>[]);
      expect((r.method, r.path), ('GET', '/api/admin/peers'));
    });

    test('host status / start / stop', () {
      final CtlRequestSpec s = build('peer', 'host', <String>['status']);
      expect((s.method, s.path), ('GET', '/api/admin/peers/host'));
      final CtlRequestSpec on = build('peer', 'host', <String>['start']);
      expect((on.method, on.path), ('POST', '/api/admin/peers/host/start'));
      final CtlRequestSpec off = build('peer', 'host', <String>['stop']);
      expect((off.method, off.path), ('POST', '/api/admin/peers/host/stop'));
      expect(() => build('peer', 'host', <String>['restart']), usageError());
      expect(() => build('peer', 'host', <String>[]), usageError());
    });

    test('pair 只收 fushi://pair 链接', () {
      const String link = 'fushi://pair?v=1&h=abc';
      final CtlRequestSpec r = build('peer', 'pair', <String>[link]);
      expect((r.method, r.path), ('POST', '/api/admin/peers/pair'));
      expect(r.body, <String, Object?>{'link': link});
      expect(() => build('peer', 'pair', <String>['https://x']), usageError());
    });
  });

  group('storage', () {
    test('root / usage', () {
      final CtlRequestSpec root = build('storage', 'root', <String>[]);
      expect((root.method, root.path), ('GET', '/api/admin/storage/root'));
      final CtlRequestSpec usage = build('storage', 'usage', <String>[]);
      expect((usage.method, usage.path), ('GET', '/api/admin/storage/usage'));
    });
  });

  group('render', () {
    String render(String group, String command, Object? data) =>
        dataCommandGroups
            .firstWhere((CtlCommandGroup g) => g.name == group)
            .find(command)!
            .render!(data);

    test('dl ls 表格与空表', () {
      expect(
        render('dl', 'ls', <String, Object?>{
          'supported': true,
          'jobs': <Object?>[],
        }),
        '（没有下载任务）',
      );
      final String table = render('dl', 'ls', <String, Object?>{
        'supported': true,
        'jobs': <Object?>[
          <String, Object?>{
            'jobId': 'j1',
            'title': 'Foo',
            'lifecycle': 'active',
            'stage': 'downloading',
            'stageProgress': 0.5,
          },
        ],
      });
      expect(table, contains('j1'));
      expect(table, contains('downloading'));
    });

    test('storage usage 换算字节并给合计', () {
      final String text = render('storage', 'usage', <String, Object?>{
        'totalBytes': 3 * 1024 * 1024,
        'categories': <Object?>[
          <String, Object?>{'id': 'books', 'bytes': 2048},
        ],
      });
      expect(text, contains('2.0 KB'));
      expect(text, contains('合计：3.0 MB'));
    });

    test('sync ls 列出可用通道名', () {
      final String text = render('sync', 'ls', <String, Object?>{
        'autoSync': true,
        'interconnectEnabled': true,
        'running': false,
        'channels': <Object?>[
          <String, Object?>{'id': 'cloud', 'backend': 'webDav'},
          <String, Object?>{'id': 'interconnect', 'backend': 'fushiServer'},
        ],
        'backends': <Object?>[],
      });
      expect(text, contains('cloud（webDav）'));
      expect(text, contains('interconnect（fushiServer）'));
    });

    test('sync run 两种结果', () {
      expect(
        render('sync', 'run', <String, Object?>{'ok': true, 'started': true}),
        contains('已开始同步'),
      );
      expect(
        render('sync', 'run', <String, Object?>{'outcome': 'completed'}),
        '同步结束：completed',
      );
    });
  });
}
