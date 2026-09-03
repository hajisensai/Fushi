import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/download_plan.dart';

void main() {
  group('DownloadPlan.ranged', () {
    test('按段大小铺满，末段取余数', () {
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/x.zip'],
        totalBytes: 250,
        partSize: 100,
      );
      expect(plan.parts.length, 3);
      expect(plan.parts.map((DownloadPart p) => p.offset), <int>[0, 100, 200]);
      expect(plan.parts.map((DownloadPart p) => p.length), <int>[100, 100, 50]);
      expect(plan.parts.last.end, 250);
    });

    test('整包来源的 remoteOffset 等于该片绝对偏移', () {
      // 这一条就是「Range 模式」的全部：URL 指的是整包，所以片在资源内的偏移
      // 与它在目标文件中的偏移相同。
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/x.zip', 'https://b/x.zip'],
        totalBytes: 200,
        partSize: 100,
      );
      expect(plan.parts[1].sources, <DownloadSource>[
        const DownloadSource(url: 'https://a/x.zip', remoteOffset: 100),
        const DownloadSource(url: 'https://b/x.zip', remoteOffset: 100),
      ]);
    });

    test('段大于总长时退化成一片', () {
      final DownloadPlan plan = DownloadPlan.ranged(
        urls: const <String>['https://a/x.zip'],
        totalBytes: 50,
        partSize: 1000,
      );
      expect(plan.parts.length, 1);
      expect(plan.parts.single.length, 50);
    });

    test('参数非法时当场拒绝', () {
      expect(
        () => DownloadPlan.ranged(
            urls: const <String>[], totalBytes: 10, partSize: 5),
        throwsArgumentError,
      );
      expect(
        () => DownloadPlan.ranged(
            urls: const <String>['https://a'], totalBytes: 0, partSize: 5),
        throwsArgumentError,
      );
      expect(
        () => DownloadPlan.ranged(
            urls: const <String>['https://a'], totalBytes: 10, partSize: 0),
        throwsArgumentError,
      );
    });
  });

  group('铺砖校验', () {
    DownloadPart part(int index, int offset, int length) => DownloadPart(
          index: index,
          offset: offset,
          length: length,
          sources: const <DownloadSource>[DownloadSource(url: 'https://a')],
        );

    test('有缝隙就拒绝（下完会是个中间带洞的坏包）', () {
      expect(
        () => DownloadPlan(
          totalBytes: 200,
          parts: <DownloadPart>[part(0, 0, 50), part(1, 100, 100)],
        ),
        throwsArgumentError,
      );
    });

    test('有重叠就拒绝', () {
      expect(
        () => DownloadPlan(
          totalBytes: 150,
          parts: <DownloadPart>[part(0, 0, 100), part(1, 50, 100)],
        ),
        throwsArgumentError,
      );
    });

    test('总长对不上就拒绝', () {
      expect(
        () => DownloadPlan(
          totalBytes: 999,
          parts: <DownloadPart>[part(0, 0, 100)],
        ),
        throwsArgumentError,
      );
    });

    test('片 index 重复就拒绝（进度会互相覆盖）', () {
      expect(
        () => DownloadPlan(
          totalBytes: 200,
          parts: <DownloadPart>[part(0, 0, 100), part(0, 100, 100)],
        ),
        throwsArgumentError,
      );
    });

    test('片没有来源就拒绝', () {
      expect(
        () => DownloadPlan(
          totalBytes: 100,
          parts: const <DownloadPart>[
            DownloadPart(
              index: 0,
              offset: 0,
              length: 100,
              sources: <DownloadSource>[],
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('乱序给片也接受（按 offset 排序后校验）', () {
      final DownloadPlan plan = DownloadPlan(
        totalBytes: 200,
        parts: <DownloadPart>[part(1, 100, 100), part(0, 0, 100)],
      );
      expect(plan.parts.length, 2);
    });
  });

  group('hasPerPartDigests', () {
    test('全带摘要为 true，缺一片为 false', () {
      DownloadPart withSha(int i, int off, String? sha) => DownloadPart(
            index: i,
            offset: off,
            length: 100,
            sha256: sha,
            sources: const <DownloadSource>[DownloadSource(url: 'https://a')],
          );
      expect(
        DownloadPlan(
          totalBytes: 200,
          parts: <DownloadPart>[
            withSha(0, 0, 'a' * 64),
            withSha(1, 100, 'b' * 64)
          ],
        ).hasPerPartDigests,
        isTrue,
      );
      expect(
        DownloadPlan(
          totalBytes: 200,
          parts: <DownloadPart>[withSha(0, 0, 'a' * 64), withSha(1, 100, null)],
        ).hasPerPartDigests,
        isFalse,
      );
    });
  });
}
