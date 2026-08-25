import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('R2 镜像先清理、再按 8GB 安全线上传，失败时回滚半成品', () {
    final String workflow = File(
      '../.github/workflows/mirror-releases.yml',
    ).readAsStringSync();

    expect(workflow, contains("MAX_BUCKET_BYTES: '8000000000'"));
    expect(
      workflow,
      contains('actions/checkout@11d5960a326750d5838078e36cf38b85af677262'),
    );
    expect(workflow, contains('node --test tool/r2_mirror_plan.test.mjs'));
    expect(workflow, contains("if: steps.capacity.outputs.allowed == 'true'"));
    expect(workflow, contains('Roll back partial upload on failure'));
    expect(workflow, contains('mirrored-rollback.json'));
    expect(workflow, contains('未知存量当 0'));
    // 空台账字面量只许出现在人工触发的引导步骤里，且必须先确认桶里没有台账
    // 才写。守卫按步骤切片，而不是全文禁止：全文禁止分不清「读失败时假装桶为空」
    // （必须 fail closed）和「显式引导一个空桶」（有存在性检查、拒绝覆盖）。
    const String emptyLedger = "echo '{\"schemaVersion\":2,\"releases\":[]}'";
    final String bootstrap = _step(
      workflow,
      'Bootstrap verified-empty R2 ledger',
    );
    final String readLedger = _step(workflow, 'Read current R2 ledger');
    expect(
      bootstrap,
      contains("github.event.inputs.bootstrap_empty_ledger == 'true'"),
      reason: '引导空台账只能由人工 dispatch 显式触发',
    );
    expect(
      bootstrap.indexOf('容量台账已经存在，拒绝覆盖'),
      allOf(greaterThan(-1), lessThan(bootstrap.indexOf(emptyLedger))),
      reason: '引导必须先查存在、拒绝覆盖，再写空台账',
    );
    expect(bootstrap, contains('本次不会上传任何 Release 资产'));
    expect(
      readLedger,
      isNot(contains('schemaVersion":2,"releases":[]')),
      reason: '台账读取失败必须 fail closed，不能假装桶为空',
    );
    expect(readLedger, contains('exit 1'));
    expect(
      emptyLedger.allMatches(workflow).length,
      1,
      reason: '空台账字面量只许在引导步骤出现一次，别的步骤不得自造空台账',
    );

    final int prune = workflow.indexOf('Prune old releases before uploading');
    final int upload = workflow.indexOf('Upload assets and commit ledger');
    expect(prune, greaterThan(0));
    expect(
      upload,
      greaterThan(prune),
      reason: '必须先释放旧版本容量，再开始上传，不能用上传后的 prune 制造日峰值',
    );

    expect(
      workflow,
      isNot(contains('Cache Reserve')),
      reason: '零付费方案只允许 R2 免费层，不启用付费 Cache Reserve',
    );
  });
}

/// 切出 workflow 里名为 [name] 的一个 step（从它的 `- name:` 到下一个 `- name:`）。
/// 步骤不存在时直接失败，免得后面的负向断言对空串真空通过。
String _step(String workflow, String name) {
  final int start = workflow.indexOf('- name: $name');
  expect(start, greaterThan(-1), reason: 'workflow 里必须有步骤「$name」');
  final int next = workflow.indexOf('\n      - name: ', start + 1);
  return workflow.substring(start, next == -1 ? workflow.length : next);
}
