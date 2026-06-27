/// 查词输入的码点（grapheme/字符）上限单一真相。
///
/// BUG-442：桌面「外部复制 → 自动查词」管线对剪贴板文本全程零长度上限。崩点在
/// `SourceLookupTextPanel.build`：逐字符建一个 `MouseRegion(GestureDetector(Text))`
/// 塞进 `Wrap`，widget 数 = 文本码点数。超长剪贴板（成千上万码点）→ 构建期巨量
/// widget → 主 isolate OOM / 引擎崩溃。
///
/// 没有人会逐字点查一段几千字的文本——查词只取「从某字符到结尾」的后缀，前
/// [kMaxLookupInputChars] 个可点字符已远超任何实际查词需要。把「输入长度无界」
/// 这个特殊情况统一收敛到同一上限：面板渲染、剪贴板/热键排队、词典搜索预处理三处
/// 都按此常量截断（用 `characters` 截断，不切碎代理对 / 字素簇）。面板的截断是硬
/// 兜底——即便上游漏截断，渲染层永不爆。
const int kMaxLookupInputChars = 2000;
