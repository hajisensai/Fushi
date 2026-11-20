import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';

/// 路线图 #3722 c28 遗留：取图请求号原来拿 `identityHashCode` 拼，不唯一——两个同页号
/// 的活页引用撞号时，桌面运行时按请求号登记的取图客户端被后一个顶掉（前一个请求被
/// 直接关掉），取消也会取消错页。
void main() {
  const MihonSourceContext context = MihonSourceContext(
    extension: MihonExtensionRef(
      packageName: 'org.example.manga',
      apkPath: 'example.apk',
    ),
    source: MihonSource(
      extensionPackage: 'org.example.manga',
      id: '7',
      name: 'Example',
      language: 'ja',
      baseUrl: 'https://example.org',
    ),
    preferences: <MihonPreference>[],
  );
  const MihonPage page = MihonPage(index: 0, url: '/p/0');

  MihonMangaPageRef ref() =>
      MihonMangaPageRef(index: 0, context: context, page: page);

  test('the same page reference always maps to the same request id', () {
    final MihonMangaPageRef a = ref();
    expect(
      MihonLibraryAdapter.mihonPageRequestId(a),
      MihonLibraryAdapter.mihonPageRequestId(a),
    );
  });

  test('distinct live page references never share a request id', () {
    // 30 万个同页号的活引用：`identityHashCode` 只有约 2^30～2^32 种取值，按生日
    // 悖论这里几乎必然撞上，旧实现会红。
    final List<MihonMangaPageRef> refs = <MihonMangaPageRef>[
      for (int i = 0; i < 300000; i++) ref(),
    ];
    final Set<String> ids = <String>{
      for (final MihonMangaPageRef r in refs)
        MihonLibraryAdapter.mihonPageRequestId(r),
    };
    expect(ids.length, refs.length);
  });
}
