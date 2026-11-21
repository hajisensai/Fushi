// BUG：tool/native_licenses.dart 在 core.symlinks=false 的 git 检出里把符号链接许可文件
// 读成「../LICENSE-MIT」这行路径（cargo git 依赖 rust-url 的 percent-encoding-iri）。
// 这里用真实 git 仓库造出两种检出形态，钉住 resolveNativeLicenseSymlink 的判据。

import 'dart:io';

import 'package:test/test.dart';

import '../../tool/native_licenses.dart';

const String _mitText = 'Copyright (c) rust-url developers\n\nMIT text\n';
const String _apacheText = 'Apache License\nVersion 2.0\n';

/// 在 [dir] 下跑 git，失败直接让测试红。
String _git(Directory dir, List<String> args) {
  final ProcessResult r = Process.runSync('git', <String>[
    '-c',
    'core.symlinks=false',
    '-c',
    'core.autocrlf=false',
    ...args,
  ], workingDirectory: dir.path);
  expect(r.exitCode, 0, reason: 'git ${args.join(' ')}: ${r.stderr}');
  return r.stdout as String;
}

/// 往索引里登记一条符号链接条目（模式 120000，内容为 [target]），再按
/// core.symlinks=false 检出——与 Windows 无建链权限时 cargo / git 的检出形态一致。
void _addSymlinkEntry(Directory repo, String path, String target) {
  final File tmp = File('${repo.path}/.link-blob')..writeAsStringSync(target);
  final String sha = _git(repo, <String>['hash-object', '-w', tmp.path]).trim();
  tmp.deleteSync();
  _git(repo, <String>[
    'update-index',
    '--add',
    '--cacheinfo',
    '120000,$sha,$path',
  ]);
  _git(repo, <String>['checkout', '--', path]);
}

/// [dir] 或它的某个上级目录含 `.git`。
bool _hasGitAncestor(Directory dir) {
  Directory d = dir.absolute;
  while (true) {
    if (Directory('${d.path}/.git').existsSync() ||
        File('${d.path}/.git').existsSync()) {
      return true;
    }
    final Directory parent = d.parent;
    if (parent.path == d.path) return false;
    d = parent;
  }
}

void main() {
  late Directory tmp;
  late Directory repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('native_license_symlink_');
    repo = Directory('${tmp.path}/rust-url')..createSync();
    _git(repo, <String>['init', '-q']);
    _git(repo, <String>['config', 'core.symlinks', 'false']);
    File('${repo.path}/LICENSE-MIT').writeAsStringSync(_mitText);
    File('${repo.path}/LICENSE-APACHE').writeAsStringSync(_apacheText);
    Directory('${repo.path}/percent_encoding').createSync();
    File(
      '${repo.path}/percent_encoding/NOTICE',
    ).writeAsStringSync('regular file\n');
    _git(repo, <String>[
      'add',
      'LICENSE-MIT',
      'LICENSE-APACHE',
      'percent_encoding/NOTICE',
    ]);
    _addSymlinkEntry(repo, 'percent_encoding/LICENSE-MIT', '../LICENSE-MIT');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('core.symlinks=false 检出的占位文本解析到链接目标的真原文', () {
    final File placeholder = File('${repo.path}/percent_encoding/LICENSE-MIT');
    // 前提：占位文件确实是「目标路径」文本——旧实现读到的就是它。
    expect(placeholder.readAsStringSync(), '../LICENSE-MIT');
    final File resolved = resolveNativeLicenseSymlink(placeholder);
    expect(readNativeLicenseText(resolved), _mitText);
  });

  test('链式符号链接逐跳解析', () {
    _addSymlinkEntry(repo, 'percent_encoding/COPYING', 'LICENSE-MIT');
    final File resolved = resolveNativeLicenseSymlink(
      File('${repo.path}/percent_encoding/COPYING'),
    );
    expect(readNativeLicenseText(resolved), _mitText);
  });

  test('反斜杠目标同样解析', () {
    _addSymlinkEntry(
      repo,
      'percent_encoding/LICENSE-APACHE',
      r'..\LICENSE-APACHE',
    );
    final File resolved = resolveNativeLicenseSymlink(
      File('${repo.path}/percent_encoding/LICENSE-APACHE'),
    );
    expect(readNativeLicenseText(resolved), _apacheText);
  });

  test('git 里的普通文件原样返回', () {
    final File notice = File('${repo.path}/percent_encoding/NOTICE');
    expect(
      readNativeLicenseText(resolveNativeLicenseSymlink(notice)),
      'regular file\n',
    );
  });

  // 系统临时目录本身可能落在某个 git 仓库里（dist worker 的临时目录在 worker 检出的
  // .git 下），那时走的是上面「外层仓库」分支；只在临时目录确实不在任何检出里时验这条。
  test(
    '不在任何 git 检出里的文件原样返回',
    () {
      final File loose = File('${tmp.path}/LICENSE')..writeAsStringSync('x\n');
      expect(resolveNativeLicenseSymlink(loose).path, loose.absolute.path);
    },
    skip: _hasGitAncestor(Directory.systemTemp)
        ? '系统临时目录 ${Directory.systemTemp.path} 在 git 检出里'
        : false,
  );

  test('最近的 .git 是不跟踪该文件的外层仓库时报错，不退回占位文本', () {
    // 依赖是没有 .git 的拷贝（vendored / 解压），落在某个外层仓库里。
    final Directory vendored = Directory('${repo.path}/vendor/dep')
      ..createSync(recursive: true);
    final File placeholder = File('${vendored.path}/LICENSE-MIT')
      ..writeAsStringSync('../LICENSE-MIT');
    expect(() => resolveNativeLicenseSymlink(placeholder), throwsStateError);
  });

  test('文件名里的通配字符按字面匹配', () {
    _addSymlinkEntry(repo, 'percent_encoding/LICENSE-[M]IT', '../LICENSE-MIT');
    File(
      '${repo.path}/percent_encoding/LICENSE-MIT-extra',
    ).writeAsStringSync('');
    final File resolved = resolveNativeLicenseSymlink(
      File('${repo.path}/percent_encoding/LICENSE-[M]IT'),
    );
    expect(readNativeLicenseText(resolved), _mitText);
  });

  test('目标越出检出根时报错，不退回占位文本', () {
    _addSymlinkEntry(repo, 'percent_encoding/LICENSE-X', '../../outside');
    File('${tmp.path}/outside').writeAsStringSync('outside\n');
    expect(
      () => resolveNativeLicenseSymlink(
        File('${repo.path}/percent_encoding/LICENSE-X'),
      ),
      throwsStateError,
    );
  });

  test('目标不存在时报错', () {
    _addSymlinkEntry(repo, 'percent_encoding/LICENSE-Y', '../missing');
    expect(
      () => resolveNativeLicenseSymlink(
        File('${repo.path}/percent_encoding/LICENSE-Y'),
      ),
      throwsStateError,
    );
  });
}
