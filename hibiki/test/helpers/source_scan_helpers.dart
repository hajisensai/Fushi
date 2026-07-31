/// 源码扫描守卫的共享工具。
///
/// 源码扫描守卫用 `contains` / `indexOf` 在真实源码上找锚点。如果扫描区间里还留着
/// 行注释，那么「把生产代码降级成注释」这种改动会让守卫继续变绿——注释里的文本
/// 照样命中 `contains`，正负向断言和定序断言全部失效（假绿）。所有 contains /
/// 定序断言都必须落在剥掉行注释之后的文本上。
///
/// 注意：切片锚点若本身是注释（例如用 `// ── Section` 当函数体结尾），必须先在原始
/// 源码上切片、再对切片调用本函数，不能先剥注释再找锚点。
library;

/// 去掉 [source] 中每行 `//` 之后的内容，保留换行结构（行数与行序不变，便于
/// 切片索引和多行断言继续工作）。
String stripLineComments(String source) {
  return source.split('\n').map((String line) {
    final int idx = line.indexOf('//');
    return idx >= 0 ? line.substring(0, idx) : line;
  }).join('\n');
}
