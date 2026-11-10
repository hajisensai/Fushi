import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Windows 无障碍树引擎加固（BUG-4379，`engine-a11y-tree-hardening.patch`）的源码守卫。
///
/// 补丁打进的是 `flutter_windows.dll`，本仓 CI 不编引擎：补丁漏打、被改回「拒收即
/// return」或丢了委托判空都不会让任何 Dart 测试变红，只会在用户机器上重新变成 UIA
/// 崩溃（BUG-2337 / BUG-2345 / BUG-3796 / BUG-4073 / BUG-4333）。这里咬住补丁的关键改动。
void main() {
  final String fushi = _fushiDir();
  final String repo = Directory(fushi).parent.path;
  final String flutterVersion = _fvmFlutterVersion(fushi);
  final String patchDir = '$repo/ci/patches/flutter-engine/$flutterVersion';
  final String patchPath = '$patchDir/engine-a11y-tree-hardening.patch';

  String patch() => _read(patchPath);

  /// 补丁里新增的行（去掉前缀 `+`），不含文件头。
  List<String> added() => patch()
      .split('\n')
      .where((String l) => l.startsWith('+') && !l.startsWith('+++'))
      .map((String l) => l.substring(1))
      .toList();

  /// 补丁里删除的行（去掉前缀 `-`），不含文件头。
  List<String> removed() => patch()
      .split('\n')
      .where((String l) => l.startsWith('-') && !l.startsWith('---'))
      .map((String l) => l.substring(1))
      .toList();

  test('补丁存在且是 LF（git apply 在 CRLF 补丁上整份失败）', () {
    final File file = File(patchPath);
    expect(file.existsSync(), isTrue, reason: patchPath);
    expect(file.readAsBytesSync().contains(13), isFalse);
  });

  test('构建脚本的 patch 步骤打这份补丁（排在 keyed mutex 之后、ANGLE 之前）', () {
    final String script = _read(
      '$repo/tool/flutter_engine/build_patched_engine.ps1',
    );
    const String applyA11y =
        "Invoke-Patch \$flutter (Join-Path \$patchDir 'engine-a11y-tree-hardening.patch')";
    const String applyKeyedMutex =
        "Invoke-Patch \$flutter (Join-Path \$patchDir 'engine-d3d-keyed-mutex.patch')";
    const String applyAngle = "'angle-scrgb-swapchain.patch')";
    expect(script, contains(applyA11y));
    expect(
      script.indexOf(applyA11y),
      greaterThan(script.indexOf(applyKeyedMutex)),
    );
    expect(script.indexOf(applyA11y), lessThan(script.indexOf(applyAngle)));
  });

  test('只改无障碍桥与节点委托（与 HDR 补丁互不重叠）', () {
    final List<String> files = RegExp(
      r'^diff --git a/(\S+) ',
      multiLine: true,
    ).allMatches(patch()).map((RegExpMatch m) => m.group(1)!).toList();
    expect(files, <String>[
      'engine/src/flutter/shell/platform/common/accessibility_bridge.cc',
      'engine/src/flutter/shell/platform/common/accessibility_bridge.h',
      'engine/src/flutter/shell/platform/common/accessibility_bridge_unittests.cc',
      'engine/src/flutter/shell/platform/common/flutter_platform_node_delegate.cc',
      'engine/src/flutter/shell/platform/windows/flutter_platform_node_delegate_windows.cc',
    ]);
    for (final String name in <String>[
      'engine-hdr-output.patch',
      'engine-underlay-composition.patch',
      'engine-impeller-hdr.patch',
      'engine-d3d-keyed-mutex.patch',
    ]) {
      final String other = _read('$patchDir/$name');
      for (final String file in files) {
        expect(other, isNot(contains('diff --git a/$file ')), reason: name);
      }
    }
  });

  test('AXTree 拒收后整树重建：清事件、销毁全部委托、新建同 id 的树', () {
    final String text = added().join('\n');
    expect(text, contains('  if (!ApplyTreePlan(plan, updated_ids)) {'));
    expect(text, contains('    RebuildTree(plan);'));
    expect(text, contains('void AccessibilityBridge::RebuildTree('));
    expect(text, contains('void AccessibilityBridge::ResetTree() {'));
    expect(text, contains('  event_generator_.ClearEvents();'));
    expect(text, contains('  id_wrapper_map_.clear();'));
    expect(text, contains('  tree_ = std::make_unique<ui::AXTree>();'));
    // 失败路径不能再「只打日志就 return」留下半应用的树。
    expect(removed(), contains('      assert(false);'));
  });

  test('目标树从保留的语义数据推出，不再把违约更新交给 AXTree', () {
    final String text = added().join('\n');
    expect(
      text,
      contains(
        '  std::unordered_map<int32_t, SemanticsNode> semantics_nodes_;',
      ),
    );
    expect(text, contains('  TreePlan PlanTree('));
    // 子节点必须有数据、每个节点只挂一个父节点。
    expect(
      text,
      contains(
        '      if (semantics_nodes_.find(child) == semantics_nodes_.end() ||',
      ),
    );
    expect(text, contains('          !placed.insert(child).second) {'));
    // 第一步摘过子节点的旧父节点，第二步必须按保留数据重新序列化（role 等随子节点变化）。
    expect(
      text,
      contains(
        '        stripped_parents.find(id) == stripped_parents.end() &&',
      ),
    );
  });

  test('release 下无效的 assert 与越界 erase 一并删除', () {
    expect(removed(), contains('      parent->child_ids.erase(iter);'));
    expect(
      removed(),
      contains('AccessibilityBridge::CreateRemoveReparentedNodesUpdate() {'),
    );
    expect(
      added().where((String l) => l.contains('assert(')),
      isEmpty,
      reason: 'assert 在 release 下是空操作，不能当校验用',
    );
  });

  test('flags 按值保存，不指向 embedder 的更新缓冲区', () {
    expect(removed(), contains('    FlutterSemanticsFlags* flags;'));
    expect(added(), contains('    FlutterSemanticsFlags flags;'));
  });

  test('OnNodeReparented 换掉指向已销毁 AXNode 的委托', () {
    final String text = patch();
    expect(
      text,
      contains(
        ' void AccessibilityBridge::OnNodeReparented(ui::AXTree* tree, ui::AXNode* node) {\n'
        '+  // The AXTree destroyed the old AXNode',
      ),
    );
    expect(added(), contains('  OnNodeCreated(tree, node);'));
  });

  test('委托：ChildAtIndex 越界与 HitTestSync 缺委托都不解引用', () {
    final List<String> lines = added();
    expect(
      lines,
      contains(
        '  ui::AXNode* child = ax_node_->GetUnignoredChildAtIndex(index);',
      ),
    );
    expect(lines, contains('  if (!child) {'));
    expect(lines, contains('    if (!win_delegate) {'));
    expect(removed(), contains('    FML_DCHECK(win_delegate)'));
  });

  test('引擎单测覆盖现场形态', () {
    final String text = added().join('\n');
    for (final String name in <String>[
      'ChildWithoutDataIsNotLeftPending',
      'NodeSentBeforeAnyParentListsItAttachesLater',
      'MovedChildThatIsNotResentKeepsItsSubtree',
      'ChildListedByTwoParentsIsPlacedOnce',
      'NodeDataOutlivesTheUpdateBuffer',
      'CustomActionDescriptionSurvivesLaterUpdates',
    ]) {
      expect(text, contains('TEST(AccessibilityBridgeTest, $name)'));
    }
  });

  test('README 记录了补丁来历与删除条件', () {
    final String readme = _read('$patchDir/README.md');
    expect(readme, contains('### `engine-a11y-tree-hardening.patch`'));
    expect(readme, contains('**删除条件**：上游 bridge 改成拒收后能自愈'));
  });
}

String _fushiDir() {
  final Directory cwd = Directory.current;
  if (File('${cwd.path}/pubspec.yaml').existsSync() &&
      Directory('${cwd.path}/windows/runner').existsSync()) {
    return cwd.path;
  }
  return '${cwd.path}/fushi';
}

String _fvmFlutterVersion(String fushi) {
  final Object? json = jsonDecode(_read('$fushi/.fvmrc'));
  return (json! as Map<String, Object?>)['flutter']! as String;
}

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');
