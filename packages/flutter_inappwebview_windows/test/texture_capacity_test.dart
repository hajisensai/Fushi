import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview_windows/src/in_app_webview/texture_capacity.dart';

/// BUG-3913：WebView 纹理容量策略。
///
/// native 每换一次共享目标纹理 / 重建一次 WGC 帧池就在引擎与系统侧留下一份永不归还
/// 的显存，所以容量必须：只增不减、容量内的尺寸变化零重新分配、一路放大时扩容次数
/// 有界（封顶在显示器尺寸）。
void main() {
  const TextureCapacity zero = (width: 0, height: 0);
  const TextureCapacity display4k = (width: 3840, height: 2160);

  /// 模拟一串改尺寸，返回容量变化（= native 重新分配）的次数与最终容量。
  ({int reallocations, TextureCapacity capacity}) replay(
    List<TextureCapacity> sizes, {
    TextureCapacity display = display4k,
  }) {
    TextureCapacity capacity = zero;
    int reallocations = 0;
    for (final TextureCapacity needed in sizes) {
      final TextureCapacity next = nextTextureCapacity(
        current: capacity,
        needed: needed,
        display: display,
      );
      expect(next.width, greaterThanOrEqualTo(needed.width));
      expect(next.height, greaterThanOrEqualTo(needed.height));
      expect(next.width, greaterThanOrEqualTo(capacity.width), reason: '只增不减');
      expect(next.height, greaterThanOrEqualTo(capacity.height));
      if (next != capacity) reallocations++;
      capacity = next;
    }
    return (reallocations: reallocations, capacity: capacity);
  }

  test('首次按内容取整到 256 档', () {
    expect(
      nextTextureCapacity(
        current: zero,
        needed: (width: 1001, height: 700),
        display: display4k,
      ),
      (width: 1024, height: 768),
    );
  });

  test('容量放得下：原样返回，缩小也不缩', () {
    const TextureCapacity current = (width: 2048, height: 1280);
    for (final TextureCapacity needed in <TextureCapacity>[
      (width: 2048, height: 1280),
      (width: 1200, height: 900),
      (width: 300, height: 200),
    ]) {
      expect(
        nextTextureCapacity(
          current: current,
          needed: needed,
          display: display4k,
        ),
        same(current),
      );
    }
  });

  test('放不下：两维一起按 1.5 倍跳档，且不超过显示器', () {
    expect(
      nextTextureCapacity(
        current: (width: 2048, height: 1280),
        needed: (width: 2100, height: 1280),
        display: display4k,
      ),
      (width: 3072, height: 2048),
      reason: '宽越界就两维一起跳档（高 1280×1.5=1920 取整 2048），对角拖动不轮流扩容',
    );
    expect(
      nextTextureCapacity(
        current: (width: 3072, height: 2048),
        needed: (width: 3100, height: 1300),
        display: display4k,
      ),
      display4k,
      reason: '4608 / 3072 被显示器 3840×2160 封顶',
    );
  });

  test('内容大过显示器：不封顶，只取整', () {
    expect(
      nextTextureCapacity(
        current: zero,
        needed: (width: 3856, height: 2128),
        display: display4k,
      ),
      (width: 4096, height: 2160),
      reason: '宽 3856 > 显示器宽，不封顶只取整；高 2128 ≤ 显示器高，封顶 2160',
    );
  });

  test('显示器尺寸未知（0）：只取整与 1.5 倍增长', () {
    expect(
      nextTextureCapacity(
        current: (width: 1024, height: 768),
        needed: (width: 1100, height: 768),
        display: zero,
      ),
      (width: 1536, height: 1280),
    );
  });

  test('BUG-3913 复现序列：4K 窗口反复改尺寸 24 次只在首次分配', () {
    final List<TextureCapacity> sizes = <TextureCapacity>[
      for (int i = 0; i < 24; i++)
        i.isEven
            ? (width: 3856, height: 2128)
            : (width: 3856 - 200 - i * 40, height: 2128 - 150 - i * 20),
    ];
    final result = replay(sizes);
    expect(result.reallocations, 1);
  });

  test('从小窗一路拖到满屏：扩容次数有界、最终停在显示器尺寸', () {
    final List<TextureCapacity> sizes = <TextureCapacity>[
      for (int w = 800; w <= 3840; w += 16)
        (width: w, height: (w * 9 / 16).round()),
    ];
    final result = replay(sizes);
    expect(result.reallocations, lessThanOrEqualTo(5));
    expect(result.capacity, display4k);
    // 到顶之后来回改尺寸不再分配。
    final TextureCapacity after = nextTextureCapacity(
      current: result.capacity,
      needed: (width: 3000, height: 1700),
      display: display4k,
    );
    expect(after, same(result.capacity));
  });

  test('textureCapacityNeeded 向上取整', () {
    expect(textureCapacityNeeded(100.2, 50.0, 2.0), (width: 201, height: 100));
    expect(textureCapacityNeeded(1000, 600, 1.5), (width: 1500, height: 900));
  });

  test('TextureLayout 把容量换回与屏幕像素 1:1 的逻辑尺寸', () {
    const TextureLayout layout = TextureLayout(
      capacity: (width: 4096, height: 2304),
      scaleFactor: 2.0,
    );
    expect(layout.logicalWidth, 2048);
    expect(layout.logicalHeight, 1152);
  });
}
