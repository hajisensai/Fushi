import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('R2 镜像先清理、再按 8GB 安全线上传，失败时回滚半成品', () {
    final String workflow = File(
      '../.github/workflows/mirror-releases.yml',
    ).readAsStringSync();

    expect(workflow, contains("MAX_BUCKET_BYTES: '8000000000'"));
    expect(workflow, contains('node --test tool/r2_mirror_plan.test.mjs'));
    expect(workflow, contains("if: steps.capacity.outputs.allowed == 'true'"));
    expect(workflow, contains('Roll back partial upload on failure'));
    expect(workflow, contains('mirrored-rollback.json'));
    expect(workflow, contains('未知存量当 0'));
    expect(workflow, contains('Bootstrap verified-empty R2 ledger'));
    expect(workflow, contains('容量台账已经存在，拒绝覆盖'));
    expect(workflow, contains('本次不会上传任何 Release 资产'));
    expect(
      workflow,
      isNot(contains("echo '{\"schemaVersion\":2,\"releases\":[]}'")),
      reason: '台账读取失败必须 fail closed，不能假装桶为空',
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

