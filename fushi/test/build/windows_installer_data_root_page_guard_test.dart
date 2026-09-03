import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/installer_data_root_bootstrap.dart';

import '../helpers/source_guard.dart';

/// 源码守卫：Windows 安装器「数据存储位置」页与 app 首启消费之间的契约。
///
/// 两侧靠一个文件名 + 一个位置（`{app}\data_root.bootstrap`）握手，任何一侧改了另一侧
/// 就静默失效（安装器写了没人读 / app 等一个永远不会出现的文件）——所以把握手点钉死：
///  - iss 里的常量与 Dart 常量同值；
///  - 页面只在全新安装、非静默时出现（`ShouldSkipPage` 走 `WizardSilent` + `IsFreshInstall`）；
///  - `IsFreshInstall` 的卸载键从 `[Setup] AppId` 派生（手抄会漏掉 `{{`→`{` 转义，
///    真值尾部是 `}}`），并兼看新旧两个平台 support 根；
///  - 下一步校验：绝对路径 + 可写预检 + 与安装目录不重合/不嵌套 + 目标下无既有
///    documents/support；
///  - `ssPostInstall` 写文件、`[UninstallDelete]` 收尾；
///  - app 侧在 `AppPaths.resolve()` **之前**消费。
///
/// **这些断言必须钉「效果」而不是「出现过」**：安装器这 143 行 Pascal 从未被 CI 编译过
/// （`release-desktop.yml` 没有 `pull_request` 触发），源码守卫是唯一的门。历史教训是
/// 早期版本只断言「函数体里出现过这些调用」，把 `and` 改成 `or`、把 `Result := False`
/// 改成 `Result := True`、删掉 `Exit;` 全都保持全绿。所以：条件用**折叠空白后的整式**
/// 比对，每条校验都断言其后真的跟着 `Result := False;`，早退都断言 `if ... then Exit;`
/// 成对出现，跨语句的时序用下标比大小。
///
/// `[Code]` 段先按 **Pascal 词法**掩码（[_maskPascalComments]：`{ }` 块注释、`(* *)`、
/// `//` 行注释一律换成等长空白，字符串字面量原样保留），把断言字面量写进任何一种注释
/// 都骗不过。不要用 `maskComments`——那是 Dart 词法器，既不认 Pascal 的 `{ }`，还会把
/// `':\'` 里的 `\'` 当 Dart 转义而在整个文件上失步。
void main() {
  String readInstallerScript() {
    final File file = File('windows/installer/fushi.iss');
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected Inno Setup script at ${file.absolute.path}',
    );
    return file.readAsStringSync();
  }

  /// `[Code]` 段，注释已按 Pascal 词法掩码。
  String readCode() {
    final String iss = readInstallerScript();
    final int start = iss.indexOf('[Code]');
    expect(
      start,
      greaterThan(0),
      reason: 'fushi.iss must have a [Code] section',
    );
    return _maskPascalComments(iss.substring(start));
  }

  String block(String code, String head) {
    final RegExpMatch? match = RegExp(
      '${RegExp.escape(head)}[\\s\\S]*?^end;',
      multiLine: true,
    ).firstMatch(code);
    expect(match, isNotNull, reason: 'expected "$head" in [Code]');
    return match!.group(0)!;
  }

  test('the Pascal comment masker actually masks all three comment forms', () {
    // 这个守卫的全部要求型断言都建立在「注释里的字面量不算数」上，所以掩码器本身也得钉。
    const String sample =
        '{ Result := False; }\n'
        '(* Result := False; *)\n'
        '// Result := False;\n'
        "Log('Result := False;');\n";
    final String masked = _maskPascalComments(sample);
    expect(masked.length, sample.length, reason: '掩码必须等长，否则所有 indexOf 切片整体错位');
    expect(
      'Result := False;'.allMatches(masked).length,
      1,
      reason: '三种注释全掩掉，只剩字符串字面量里的那一处',
    );
    expect(masked.contains("Log('Result := False;')"), isTrue);
  });

  test('bootstrap file name matches between installer and app', () {
    final String iss = readInstallerScript();
    final RegExpMatch? constant = RegExp(
      r"DataRootBootstrapFileName\s*=\s*'([^']+)'",
    ).firstMatch(iss);
    expect(
      constant,
      isNotNull,
      reason: 'fushi.iss must declare DataRootBootstrapFileName',
    );
    expect(constant!.group(1), installerDataRootBootstrapFileName);

    expect(
      readCode().contains(
        r"ExpandConstant('{app}\' + DataRootBootstrapFileName)",
      ),
      isTrue,
      reason:
          'bootstrap must be written next to the exe ({app}); the app '
          'locates it via Platform.resolvedExecutable',
    );
    final RegExpMatch? uninstallDelete = RegExp(
      r'^\[UninstallDelete\]([\s\S]*?)^\[',
      multiLine: true,
    ).firstMatch(iss);
    expect(uninstallDelete, isNotNull, reason: '[UninstallDelete] section');
    expect(
      uninstallDelete!
          .group(1)!
          .contains(
            'Type: files; Name: "{app}\\$installerDataRootBootstrapFileName"',
          ),
      isTrue,
      reason: '[UninstallDelete] must remove the bootstrap file',
    );
  });

  test('data root page exists and is only offered on a fresh, non-silent '
      'install', () {
    final String code = readCode();
    expect(
      code.contains('CreateInputDirPage(wpSelectDir'),
      isTrue,
      reason: 'the data root page must follow the install dir page',
    );

    final String skip = block(
      code,
      'function ShouldSkipPage(PageID: Integer): Boolean;',
    );
    expect(skip.contains('DataRootPage.ID'), isTrue);
    expect(
      skip.contains(
        'DataRootPageOffered := (not WizardSilent()) and IsFreshInstall()',
      ),
      isTrue,
      reason:
          'silent installs must skip the page (Inno aborts the whole '
          'install when a ClickThrough NextButtonClick returns False) and the '
          'decision must be remembered for ssPostInstall (the uninstall key '
          'exists by then)',
    );
    // 效果断言：算出来的 DataRootPageOffered 必须真的驱动跳过与否。少了这条，
    // `Result := False;`（=每次升级都弹这页）保持全绿。
    expect(
      _collapse(skip).contains('Result := not DataRootPageOffered;'),
      isTrue,
      reason:
          'the skip decision must be exactly "not DataRootPageOffered"; '
          'anything else re-offers the page on upgrades/reinstalls',
    );
  });

  test('uninstall key derives from [Setup] AppId and both support roots are '
      'probed', () {
    final String code = readCode();
    final String key = block(code, 'function FushiUninstallKey(): String;');
    expect(
      key.contains(
        r"ExpandConstant('{#SetupSetting("
        '"AppId"'
        r")}')",
      ),
      isTrue,
      reason:
          'AppId must come from [Setup] via ISPP + ExpandConstant ({{ → {); '
          'a hand-copied GUID misses the trailing "}}" of the real AppId and '
          'RegKeyExists never matches',
    );
    expect(key.contains(r"'_is1'"), isTrue);
    expect(
      RegExp(r'Uninstall\\\{[0-9A-Fa-f-]{36}').hasMatch(code),
      isFalse,
      reason: 'no hand-copied GUID anywhere in [Code]',
    );

    // 平台 support 根 = %APPDATA%\<CompanyName>\<ProductName>，两个名字的真相源是
    // exe 的版本资源。硬抄进 iss 的字面量必须与 Runner.rc 对得上，否则改了产品名之后
    // IsFreshInstall 会在一个不存在的目录上判「全新」，对老用户重新弹页。
    final String rc = File('windows/runner/Runner.rc').readAsStringSync();
    final String company = _rcValue(rc, 'CompanyName');
    final String product = _rcValue(rc, 'ProductName');

    final String fresh = block(code, 'function IsFreshInstall(): Boolean;');
    // 整式比对（折叠空白）：三个条件必须用 and 串联。三条独立 contains 挡不住
    // `and` → `or`——那会让 IsFreshInstall 对任何既有安装恒真。
    expect(
      _collapse(fresh).contains(
        'Result := (not RegKeyExists(HKCU, FushiUninstallKey())) '
        "and (not DirExists(ExpandConstant('{userappdata}\\$company\\$product'))) "
        r"and (not DirExists(ExpandConstant('{userappdata}\Hibiki\Hibiki')));",
      ),
      isTrue,
      reason:
          'IsFreshInstall must AND all three probes: the uninstall key, the '
          'current support root (%APPDATA%\\$company\\$product, matching '
          'windows/runner/Runner.rc) and the legacy %APPDATA%\\Hibiki\\Hibiki '
          '(migrateLegacySupportDir renames it on first launch, so it counts '
          'as an existing install). OR-ing them makes every upgrade look '
          'fresh; got:\n${_collapse(fresh)}',
    );
  });

  test('NextButtonClick validates the data root page and every check really '
      'rejects', () {
    final String next = block(
      readCode(),
      'function NextButtonClick(CurPageID: Integer): Boolean;',
    );
    final int dataRootBranch = next.indexOf('CurPageID = DataRootPage.ID');
    expect(dataRootBranch, greaterThan(0));
    final String branch = next.substring(dataRootBranch);

    // 顺序即语义：绝对路径预检必须排在最前——空串 / 相对路径会让后面三条校验落到
    // 当前盘根或 setup 工作目录上「通过」，引导文件照写，直到 app 侧才被无声丢弃。
    final List<String> conditions = <String>[
      'Length(DataRoot) < 3',
      'IsSameOrAncestorDir(DataRoot, WizardDirValue)',
      "DirExists(AddBackslash(DataRoot) + '${AppPaths.dataRootDocumentsChild}')",
      'InstallDirWritable(DataRoot)',
    ];
    final List<int> starts = <int>[];
    int cursor = 0;
    for (final String condition in conditions) {
      final int at = branch.indexOf(condition, cursor);
      expect(
        at,
        greaterThanOrEqualTo(0),
        reason:
            'missing (or out of order) data-root check: $condition\n'
            'checks must appear in this order: $conditions',
      );
      starts.add(at);
      cursor = at + condition.length;
    }

    // 反向绑定：Dart 侧改了子目录常量，这里会当场变红而不是静默校验一个不存在的名字。
    expect(
      branch.contains(
        "DirExists(AddBackslash(DataRoot) + '${AppPaths.dataRootSupportChild}')",
      ),
      isTrue,
      reason:
          'pre-existing ${AppPaths.dataRootDocumentsChild}/'
          '${AppPaths.dataRootSupportChild} subtree must be rejected '
          '(targetNotEmpty); the names come from AppPaths',
    );
    expect(
      branch.contains('IsSameOrAncestorDir(WizardDirValue, DataRoot)'),
      isTrue,
      reason: 'containment must be checked in both directions',
    );
    expect(
      branch.contains(r"Copy(DataRoot, 2, 2) <> ':\'"),
      isTrue,
      reason: 'absolute path precheck must accept drive paths (X:\\...)',
    );
    expect(
      branch.contains(r"Copy(DataRoot, 1, 2) <> '\\'"),
      isTrue,
      reason:
          'absolute path precheck must accept UNC paths (\\\\server\\share)',
    );

    // 效果断言：每条校验之后必须真的 `Result := False;`，且这一段里不许出现
    // `Result := True`。只断言「条件出现过」时，把四处 False 全改成 True 也是全绿。
    for (int i = 0; i < starts.length; i++) {
      final int end = i + 1 < starts.length ? starts[i + 1] : branch.length;
      final String segment = branch.substring(starts[i], end);
      expect(
        segment.contains('Result := False;'),
        isTrue,
        reason:
            'check "${conditions[i]}" must reject with Result := False; '
            'a MsgBox alone only annoys the user and lets the value through',
      );
      expect(
        segment.contains('Result := True'),
        isFalse,
        reason: 'check "${conditions[i]}" must not re-allow the value',
      );
    }
    // 前三条各自 Exit;（后面还有校验），最后一条是分支末尾，靠 end 收口。
    expect(
      'Exit;'.allMatches(branch.substring(0, starts.last)).length,
      starts.length - 1,
      reason:
          'every non-final check must Exit; after rejecting — otherwise a '
          'later check can run on a value an earlier one already rejected',
    );
  });

  test('ssPostInstall writes the bootstrap only when the page was offered', () {
    final String code = readCode();
    final String write = block(code, 'procedure WriteDataRootBootstrap();');
    // `if ... then` 和它的 `Exit;` 必须成对：只断言 if 行时，删掉 Exit; 保持全绿，
    // 而那意味着每一次安装（含升级、含静默）都写引导文件。
    expect(
      RegExp(r'if not DataRootPageOffered then\s+Exit;').hasMatch(write),
      isTrue,
      reason:
          'the write must bail out when the page was never shown; the `if` '
          'without its `Exit;` writes the bootstrap on every install',
    );
    expect(
      RegExp(r'if DataRootPage = nil then\s+Exit;').hasMatch(write),
      isTrue,
      reason: 'do not dereference the page object on an implicit invariant',
    );
    expect(
      RegExp(r"if Target = '' then\s+Exit;").hasMatch(write),
      isTrue,
      reason: 'never write an empty bootstrap line',
    );
    expect(
      write.contains('SaveStringsToUTF8File('),
      isTrue,
      reason: 'paths may contain non-ASCII; SaveStringToFile writes ANSI',
    );

    final String step = block(
      code,
      'procedure CurStepChanged(CurStep: TSetupStep);',
    );
    final int gate = step.indexOf('if CurStep <> ssPostInstall then');
    expect(gate, greaterThanOrEqualTo(0));
    final int gateExit = step.indexOf('Exit;', gate);
    expect(
      gateExit,
      greaterThan(gate),
      reason: 'the ssPostInstall gate needs its Exit;',
    );
    final int call = step.indexOf('WriteDataRootBootstrap();');
    expect(
      call,
      greaterThan(gateExit),
      reason:
          'the bootstrap must be written only at ssPostInstall (after the '
          'files landed); moving the call above the gate writes it at every '
          'setup step, including ones a failed install rolls back from',
    );
  });

  test('app consumes the bootstrap before AppPaths.resolve()', () {
    final String appModel = maskComments(
      File('lib/src/models/app_model.dart').readAsStringSync(),
    );
    final int consume = appModel.indexOf(
      'await consumeInstallerDataRootBootstrap();',
    );
    final int resolve = appModel.indexOf(
      '_appPaths = await AppPaths.resolve();',
    );
    expect(consume, greaterThan(0));
    expect(
      resolve,
      greaterThan(consume),
      reason: 'resolve() reads the data_root pref the bootstrap writes',
    );
  });
}

/// 折叠所有连续空白为单个空格，用于对多行 Pascal 表达式做**整式**比对
/// （逐条 `contains` 挡不住 `and` → `or`）。
String _collapse(String source) =>
    source.replaceAll(RegExp(r'\s+'), ' ').trim();

/// 从 `windows/runner/Runner.rc` 的 `VALUE "<name>", "<value>" "\0"` 里取值。
String _rcValue(String rc, String name) {
  final RegExpMatch? match = RegExp(
    'VALUE\\s+"${RegExp.escape(name)}"\\s*,\\s*"([^"]*)"',
  ).firstMatch(rc);
  expect(match, isNotNull, reason: 'Runner.rc must declare $name');
  final String value = match!.group(1)!;
  expect(value.isNotEmpty, isTrue, reason: '$name must not be empty');
  return value;
}

/// Pascal（Inno Setup Pascal Script）词法掩码：把 `{ }`、`(* *)`、`//` 三种注释换成
/// **等长空白**（换行保留），字符串字面量原样保留。
///
/// 为什么不能复用 `maskComments`（Dart 词法器）：
///  - Dart 不认 Pascal 的 `{ }` 块注释——把断言字面量塞进块注释就能骗绿；
///  - Pascal 里 `\` 不是转义符，`':\'` 是一个完整的两字符串。Dart 词法器会把 `\'`
///    当转义、吃掉后面的代码去找下一个引号，从此在整个文件上失步。
///
/// Pascal 字符串规则：`'` 开始，`''` 表示一个字面单引号，单个 `'` 结束，不跨行。
/// 块注释不嵌套（与 Inno 自身一致：注释里出现 `}` 就提前结束）。
String _maskPascalComments(String source) {
  final StringBuffer out = StringBuffer();
  final int n = source.length;
  int i = 0;

  void maskThrough(int end) {
    for (int k = i; k < end && k < n; k++) {
      out.write(source[k] == '\n' ? '\n' : ' ');
    }
    i = end < n ? end : n;
  }

  while (i < n) {
    final String c = source[i];
    if (c == "'") {
      out.write(c);
      i++;
      while (i < n) {
        if (source[i] == "'") {
          out.write("'");
          i++;
          // `''` 是转义的单引号，字符串继续。
          if (i < n && source[i] == "'") {
            out.write("'");
            i++;
            continue;
          }
          break;
        }
        if (source[i] == '\n') break; // Pascal 字符串不跨行：容错收口。
        out.write(source[i]);
        i++;
      }
      continue;
    }
    if (c == '{') {
      final int close = source.indexOf('}', i);
      maskThrough(close < 0 ? n : close + 1);
      continue;
    }
    if (c == '(' && i + 1 < n && source[i + 1] == '*') {
      final int close = source.indexOf('*)', i + 2);
      maskThrough(close < 0 ? n : close + 2);
      continue;
    }
    if (c == '/' && i + 1 < n && source[i + 1] == '/') {
      int end = source.indexOf('\n', i);
      if (end < 0) end = n;
      maskThrough(end);
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
