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
      'sub',
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

    test('run --conflicts：策略原样带上，限值域', () {
      expect(
        build('sync', 'run', <String>[
          '--conflicts',
          'keep-remote',
          '--wait',
        ]).body,
        <String, Object?>{'wait': true, 'conflicts': 'keep-remote'},
      );
      expect(
        build('sync', 'run', <String>['cloud', '--conflicts', 'ask']).body,
        <String, Object?>{
          'channels': <String>['cloud'],
          'conflicts': 'ask',
        },
      );
      expect(
        () => build('sync', 'run', <String>['--conflicts', 'local']),
        throwsA(isA<FormatException>()),
      );
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
      // 磁链 / 种子也能按域入库（第二轮）。
      expect(
        build('dl', 'add', <String>[magnet, '--kind', 'novel']).body,
        <String, Object?>{'target': magnet, 'mediaKind': 'novel'},
      );
      expect(() => build('dl', 'add', <String>[]), usageError());
      expect(
        () => build('dl', 'add', <String>[magnet, '--kind', 'anime']),
        throwsA(isA<ArgParserException>()),
      );
    });

    test('cancel / pause / retry / resume', () {
      final CtlRequestSpec c = build('dl', 'cancel', <String>['j1']);
      expect((c.method, c.path), ('POST', '/api/admin/downloads/j1/cancel'));
      final CtlRequestSpec pause = build('dl', 'pause', <String>['j1']);
      expect((pause.method, pause.path), (c.method, c.path));
      final CtlRequestSpec r = build('dl', 'retry', <String>['j1']);
      expect((r.method, r.path), ('POST', '/api/admin/downloads/j1/retry'));
      final CtlRequestSpec res = build('dl', 'resume', <String>['direct:3']);
      expect(
        (res.method, res.path),
        ('POST', '/api/admin/downloads/direct%3A3/resume'),
      );
      expect(() => build('dl', 'resume', <String>[]), usageError());
    });

    test('add 种子完整参数：目标库 / 字幕 / 文件 / 身份 / 设备 / 优先级', () {
      final CtlRequestSpec r = build('dl', 'add', <String>[
        'a.torrent',
        '--kind',
        'tv',
        '--source',
        '3',
        '--subtitles',
        'bestEffort',
        '--files',
        '0,2',
        '--files',
        '5',
        '--year',
        '2024',
        '--provider',
        'anidb',
        '--external-id',
        '123',
        '--device',
        'host-1',
        '--priority',
        'high',
      ]);
      expect(r.body, <String, Object?>{
        'target': p.normalize(p.absolute('a.torrent')),
        'mediaKind': 'tv',
        'source': 3,
        'subtitlePolicy': 'bestEffort',
        'files': <String>['0', '2', '5'],
        'year': 2024,
        'metadataProvider': 'anidb',
        'externalId': '123',
        'device': 'host-1',
        'priority': 1,
      });
      expect(
        build('dl', 'add', <String>[
          'magnet:?xt=urn:btih:a',
          '--priority',
          '-5',
          '--device',
          'local',
        ]).body,
        containsPair('priority', -5),
      );
    });

    test('add 参数组合错误', () {
      const String magnet = 'magnet:?xt=urn:btih:a';
      // 磁链没有文件清单。
      expect(
        () => build('dl', 'add', <String>[magnet, '--files', '1']),
        usageError(),
      );
      // 资料源与 id 成对。
      expect(
        () => build('dl', 'add', <String>[magnet, '--provider', 'tmdb']),
        usageError(),
      );
      // 非视频不收目标库 / 年份。
      expect(
        () => build('dl', 'add', <String>[
          magnet,
          '--kind',
          'manga',
          '--source',
          '1',
        ]),
        usageError(),
      );
      // 直链不收种子专属参数。
      expect(
        () => build('dl', 'add', <String>[
          'https://x/a.epub',
          '--kind',
          'novel',
          '--subtitles',
          'required',
        ]),
        usageError(),
      );
      expect(
        () => build('dl', 'add', <String>[magnet, '--priority', 'urgent']),
        usageError(),
      );
      expect(
        () => build('dl', 'add', <String>[magnet, '--source', 'x']),
        usageError(),
      );
    });

    test('--device：远端任务的 ls / get / cancel / retry / rm', () {
      final CtlRequestSpec ls = build('dl', 'ls', <String>['--device', 'h1']);
      expect(ls.query, <String, String>{'device': 'h1'});
      expect(build('dl', 'ls', <String>[]).query, isEmpty);
      expect(
        build('dl', 'get', <String>['j1', '--device', 'PC']).query,
        <String, String>{'device': 'PC'},
      );
      for (final String cmd in <String>['cancel', 'pause', 'retry']) {
        expect(
          build('dl', cmd, <String>['j1', '--device', 'h1']).body,
          <String, Object?>{'device': 'h1'},
          reason: cmd,
        );
        expect(build('dl', cmd, <String>['j1']).body, isEmpty, reason: cmd);
      }
      expect(
        build('dl', 'rm', <String>['j1', '-y', '--device', 'h1']).query,
        <String, String>{'confirm': 'true', 'device': 'h1'},
      );
      // BUG-3437：远端任务也能选删不删文件（host 不支持时由 app 侧明确报错）。
      expect(
        build('dl', 'rm', <String>[
          'j1',
          '-y',
          '--device',
          'h1',
          '--delete-files',
        ]).query,
        <String, String>{
          'confirm': 'true',
          'deleteFiles': 'true',
          'device': 'h1',
        },
      );
    });

    test('priority / detail / targets', () {
      final CtlRequestSpec pr = build('dl', 'priority', <String>['j1', 'low']);
      expect(
        (pr.method, pr.path),
        ('POST', '/api/admin/downloads/j1/priority'),
      );
      expect(pr.body, <String, Object?>{'priority': -1});
      expect(
        build('dl', 'priority', <String>['j1', '7']).body,
        <String, Object?>{'priority': 7},
      );
      expect(() => build('dl', 'priority', <String>['j1']), usageError());
      expect(
        () => build('dl', 'priority', <String>['j1', 'top']),
        usageError(),
      );
      final CtlRequestSpec d = build('dl', 'detail', <String>['j/1']);
      expect((d.method, d.path), ('GET', '/api/admin/downloads/j%2F1/details'));
      final CtlRequestSpec t = build('dl', 'targets', <String>[]);
      expect((t.method, t.path), ('GET', '/api/admin/download-targets'));
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
      // --yes：跳过 app 确认框直接配对。
      expect(
        build('peer', 'pair', <String>[link, '--yes']).body,
        <String, Object?>{'link': link, 'confirm': true},
      );
    });

    test('pair-link 签发 / --revoke 作废', () {
      final CtlRequestSpec issue = build('peer', 'pair-link', <String>[]);
      expect(
        (issue.method, issue.path),
        ('POST', '/api/admin/peers/pair-link'),
      );
      final CtlRequestSpec revoke = build('peer', 'pair-link', <String>[
        '--revoke',
      ]);
      expect(
        (revoke.method, revoke.path),
        ('DELETE', '/api/admin/peers/pair-link'),
      );
    });

    test('revoke / forget 必须 --yes，id 按段编码', () {
      expect(() => build('peer', 'revoke', <String>['p1']), usageError());
      final CtlRequestSpec r = build('peer', 'revoke', <String>['p/1', '-y']);
      expect((r.method, r.path), ('DELETE', '/api/admin/peers/clients/p%2F1'));
      expect(r.query, <String, String>{'confirm': 'true'});
      expect(() => build('peer', 'forget', <String>['host-1']), usageError());
      final CtlRequestSpec f = build('peer', 'forget', <String>[
        'https://192.168.1.2:7000',
        '--yes',
      ]);
      expect(f.path, '/api/admin/peers/hosts/https%3A%2F%2F192.168.1.2%3A7000');
      expect(f.query, <String, String>{'confirm': 'true'});
    });
  });

  group('storage', () {
    test('root / usage', () {
      final CtlRequestSpec root = build('storage', 'root', <String>[]);
      expect((root.method, root.path), ('GET', '/api/admin/storage/root'));
      final CtlRequestSpec usage = build('storage', 'usage', <String>[]);
      expect((usage.method, usage.path), ('GET', '/api/admin/storage/usage'));
    });

    test('migrate：真迁移要 --yes，--dry-run 不要；目录转绝对路径', () {
      expect(() => build('storage', 'migrate', <String>['d']), usageError());
      expect(() => build('storage', 'migrate', <String>[]), usageError());
      final CtlRequestSpec dry = build('storage', 'migrate', <String>[
        'd',
        '--dry-run',
      ]);
      expect((dry.method, dry.path), ('POST', '/api/admin/storage/migrate'));
      expect(dry.body, <String, Object?>{
        'path': p.normalize(p.absolute('d')),
        'dryRun': true,
      });
      expect(
        build('storage', 'migrate', <String>['d', '-y']).body,
        <String, Object?>{
          'path': p.normalize(p.absolute('d')),
          'confirm': true,
        },
      );
      final CtlRequestSpec st = build('storage', 'migrate-status', <String>[]);
      expect((st.method, st.path), ('GET', '/api/admin/storage/migrate'));
    });
  });

  group('backup 第二轮', () {
    test('create 指定书 / 视频与后台模式', () {
      final CtlRequestSpec r = build('backup', 'create', <String>[
        '--book',
        'bk1',
        '--book',
        'bk2',
        '--video',
        'v1',
        '--no-wait',
      ]);
      expect(r.body, <String, Object?>{
        'output': p.normalize(p.current),
        'books': <String>['bk1', 'bk2'],
        'videos': <String>['v1'],
        'wait': false,
      });
      final CtlRequestSpec st = build('backup', 'status', <String>[]);
      expect((st.method, st.path), ('GET', '/api/admin/backups/status'));
    });
  });

  group('sub', () {
    test('ls / get / items / check（单条与全部）', () {
      expect(build('sub', 'ls', <String>[]).path, '/api/admin/subscriptions');
      expect(
        build('sub', 'get', <String>['video-discovery-1']).path,
        '/api/admin/subscriptions/video-discovery-1',
      );
      expect(
        build('sub', 'items', <String>['a/b']).path,
        '/api/admin/subscriptions/a%2Fb/items',
      );
      final CtlRequestSpec all = build('sub', 'check', <String>[]);
      expect(all.method, 'POST');
      expect(all.path, '/api/admin/subscriptions/check');
      expect(
        build('sub', 'check', <String>['s1']).path,
        '/api/admin/subscriptions/s1/check',
      );
      expect(() => build('sub', 'get', <String>[]), usageError());
    });

    test('enable / disable 走同一条路由，body 区分', () {
      final CtlRequestSpec on = build('sub', 'enable', <String>['s1']);
      expect(on.path, '/api/admin/subscriptions/s1/enable');
      expect(on.body, <String, Object?>{'enabled': true});
      expect(build('sub', 'disable', <String>['s1']).body, <String, Object?>{
        'enabled': false,
      });
    });

    test('edit 只带给出的项；--start-after none 清空；规则空串 = 去掉', () {
      final CtlRequestSpec r = build('sub', 'edit', <String>[
        's1',
        '--query',
        'Nia Liston 1080p',
        '--start-after',
        '3',
        '--subtitles',
        'required',
        '--source',
        '7',
        '--group',
        'SubsPlease,Erai-raws',
        '--resolution',
        '',
      ]);
      expect(r.method, 'PUT');
      expect(r.path, '/api/admin/subscriptions/s1');
      expect(r.body, <String, Object?>{
        'searchQuery': 'Nia Liston 1080p',
        'startAfterEpisode': 3,
        'subtitlePolicy': 'required',
        'source': 7,
        'releaseGroups': <String>['SubsPlease', 'Erai-raws'],
        'resolutions': <String>[],
      });
      final CtlRequestSpec clear = build('sub', 'edit', <String>[
        's1',
        '--start-after',
        'none',
      ]);
      expect(clear.body, <String, Object?>{'startAfterEpisode': null});
      expect(() => build('sub', 'edit', <String>['s1']), usageError());
      expect(
        () => build('sub', 'edit', <String>['s1', '--start-after', 'x']),
        usageError(),
      );
    });

    test('rm 必须 --yes，并带 confirm', () {
      expect(() => build('sub', 'rm', <String>['s1']), usageError());
      final CtlRequestSpec r = build('sub', 'rm', <String>['s1', '--yes']);
      expect(r.method, 'DELETE');
      expect(r.path, '/api/admin/subscriptions/s1');
      expect(r.query, <String, String>{'confirm': 'true'});
    });
  });

  group('render', () {
    String render(String group, String command, Object? data) =>
        dataCommandGroups
            .firstWhere((CtlCommandGroup g) => g.name == group)
            .find(command)!
            .render!(data);

    test('sub ls 状态列：启用 / 已停用 / 已完成 / 出错；后端未就绪有提示', () {
      final String out = render('sub', 'ls', <String, Object?>{
        'supported': false,
        'subscriptions': <Object?>[
          <String, Object?>{'subscriptionId': 'a', 'enabled': true},
          <String, Object?>{'subscriptionId': 'b', 'enabled': false},
          <String, Object?>{
            'subscriptionId': 'c',
            'enabled': false,
            'fulfilledAt': 1,
          },
          <String, Object?>{
            'subscriptionId': 'd',
            'enabled': true,
            'lastError': 'boom',
          },
        ],
      });
      expect(out, startsWith('本机下载后端未就绪'));
      for (final String s in <String>['启用', '已停用', '已完成', '出错：boom']) {
        expect(out, contains(s));
      }
      expect(
        render('sub', 'ls', <String, Object?>{
          'supported': true,
          'subscriptions': <Object?>[],
        }),
        contains('没有订阅'),
      );
    });

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
        'autoSync': false,
        'interconnectAutoSync': true,
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
      // 两条通道的自动同步开关分开报（反馈 5nWEirdCs2）。
      expect(text, contains('云同步自动同步：关'));
      expect(text, contains('互联自动同步：开'));
    });

    test('dl add 远端 / dl detail / dl targets / pair-link / migrate', () {
      expect(
        render('dl', 'add', <String, Object?>{
          'jobId': 'r1',
          'title': 'T',
          'device': 'PC',
          'remote': true,
        }),
        '已入队：r1（T） → PC',
      );
      final String detail = render('dl', 'detail', <String, Object?>{
        'jobId': 'j1',
        'title': 'T',
        'lifecycle': 'active',
        'stage': 'download',
        'torrent': <String, Object?>{
          'name': 'N',
          'state': 'downloading',
          'downRateBps': 2048,
          'upRateBps': 0,
        },
        'location': '/dl/N',
        'files': <Object?>[
          <String, Object?>{
            'index': 0,
            'name': 'ep1.mkv',
            'bytes': 1024,
            'progress': 0.5,
          },
        ],
      });
      expect(detail, contains('ep1.mkv'));
      expect(detail, contains('50%'));
      expect(detail, contains('位置：/dl/N'));
      final String targets = render('dl', 'targets', <String, Object?>{
        'localBackend': 'embedded',
        'executionDevice': 'local',
        'sources': <Object?>[
          <String, Object?>{
            'id': 3,
            'label': 'Anime',
            'rootPath': '/v',
            'default': true,
          },
        ],
        'hosts': <Object?>[],
      });
      expect(targets, contains('Anime'));
      expect(
        render('dl', 'ls', <String, Object?>{
          'device': 'PC',
          'remote': true,
          'jobs': <Object?>[],
        }),
        '互联 host「PC」上的任务：\n（没有任务）',
      );
      expect(targets, contains('（无在线 host）'));
      expect(
        render('peer', 'pair-link', <String, Object?>{
          'link': 'fushi://pair?h=x',
          'oneTime': true,
        }),
        startsWith('fushi://pair?h=x'),
      );
      expect(
        render('storage', 'migrate-status', <String, Object?>{
          'active': true,
          'copiedFiles': 3,
          'totalFiles': 10,
        }),
        '正在迁移：3 / 10 个文件',
      );
      expect(
        render('backup', 'status', <String, Object?>{
          'active': true,
          'progress': 0.25,
        }),
        '正在导出备份：25%',
      );
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

    test('sync run --conflicts 的结果：已裁决 / 未解决清单', () {
      expect(
        render('sync', 'run', <String, Object?>{
          'ok': true,
          'started': true,
          'conflictPolicy': 'newest',
        }),
        contains('newest'),
      );
      final String text = render('sync', 'run', <String, Object?>{
        'ok': false,
        'outcome': 'completed',
        'conflicts': <String, Object?>{
          'policy': 'ask',
          'resolved': <Object?>[],
          'unresolved': <Object?>[
            <String, Object?>{
              'type': 'book',
              'title': 'BookA',
              'localUpdatedAt': 120,
              'remoteUpdatedAt': 100,
            },
          ],
        },
      });
      expect(text, contains('冲突策略 ask'));
      expect(text, contains('未解决的冲突'));
      expect(text, contains('BookA'));
    });
  });
}
