import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

CtlCommandGroup _group() =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == 'feedback');

CtlRequestSpec _build(List<String> args) {
  final CtlCommandSpec spec = _group().find('submit')!;
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

void main() {
  test('feedback 组只注册一次，含 submit', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'feedback'),
      hasLength(1),
    );
    expect(
      <String>[for (final CtlCommandSpec s in _group().commands) s.name],
      <String>['submit'],
    );
  });

  test('submit：没 --yes 报用法错误（发出后撤不回）；空标题报用法错误', () {
    expect(() => _build(<String>['标题']), _usageError());
    expect(() => _build(<String>['--yes']), _usageError());
    expect(() => _build(<String>['  ', '--yes']), _usageError());
  });

  test('submit：隐私开关总是显式进 body，默认与提交页一致（日志只有 bug 默认附带）', () {
    final CtlRequestSpec plain = _build(<String>['AI 助手没法反馈', '--yes']);
    expect(plain.method, 'POST');
    expect(plain.path, '/api/admin/feedback');
    expect(plain.body, <String, Object?>{
      'category': 'bug',
      'title': 'AI 助手没法反馈',
      'includeLogs': true,
      'includeDeviceInfo': true,
      'linkAccount': true,
      'confirm': true,
    });
    final CtlRequestSpec custom = _build(<String>[
      '想要导出',
      '-c',
      'suggestion',
      '--body',
      '  详情  ',
      '--no-logs',
      '--no-device-info',
      '--no-link-account',
      '-y',
    ]);
    expect(custom.body, <String, Object?>{
      'category': 'suggestion',
      'title': '想要导出',
      'body': '详情',
      'includeLogs': false,
      'includeDeviceInfo': false,
      'linkAccount': false,
      'confirm': true,
    });
    // 建议 / 其他不默认附日志（提交页 feedbackDefaultIncludeLogs 同口径）。
    for (final String category in <String>['suggestion', 'other']) {
      expect(
        _build(<String>['x', '-c', category, '--yes']).body!['includeLogs'],
        isFalse,
        reason: category,
      );
    }
    expect(
      _build(<String>[
        'x',
        '-c',
        'suggestion',
        '--logs',
        '--yes',
      ]).body!['includeLogs'],
      isTrue,
    );
    expect(
      _build(<String>['x', '--no-logs', '--yes']).body!['includeLogs'],
      isFalse,
    );
    expect(
      () => _build(<String>['x', '-c', 'praise', '--yes']),
      throwsA(isA<ArgParserException>()),
    );
  });

  test('渲染：id、附带了什么、失败附件提示', () {
    final String text = _group().find('submit')!.render!(<String, Object?>{
      'id': 'abcDEF1234',
      'title': 't',
      'logsAttached': true,
      'deviceInfoAttached': false,
      'failedAttachments': 1,
    });
    expect(text, contains('#abcDEF1234'));
    expect(text, contains('无设备信息'));
    expect(text, contains('1 个附件没传上去'));
  });
}
