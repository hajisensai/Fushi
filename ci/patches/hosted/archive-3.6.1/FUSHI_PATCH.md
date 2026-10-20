# Fushi：zip extra field 越界读修复

archive 3.6.1 遍历 zip extra field 的两处循环（中央目录 `lib/src/zip/zip_file_header.dart`、
加密条目的本地头 `lib/src/zip/zip_file.dart`）以 `while (!extra.isEOS)` 为条件。extra field
末尾若剩 1～3 字节（不足一个 `[id:2][size:2]` 块头——打包工具的对齐填充就是这种形状），循环仍会
进去执行 `readUint16`，而 `InputStream.readUint16` 是不查边界的 `buffer[offset++]`：

- release（AOT）构建报 `RangeError (length): Invalid value: Not in inclusive range 0..36: 37`
  （37 字节的 extra field 被读了下标 37），JIT 下是 `RangeError (index)`；
- 结果是整本 EPUB / CBZ 打不开，导入对话框弹 `Import failed: RangeError ...`。

改法与上游 archive 4.x 相同：循环条件改成 `extra.length >= 4`；另外块声明的 `size` 超过剩余字节时
停止（截断的坏块，4.x 会把越界的 `readBytes` 视图交给 zip64 解析继续越界读）。合法的 extra field
解析结果不变。

回归测试：`packages/fushi_engine/test/epub/epub_zip_extra_field_padding_test.dart`。

**删除条件**：本仓升到 archive 4.x（上游已修，见 4.x `codecs/zip/zip_file_header.dart` 的
`while (extra.length >= 4)`）后删除本目录。目前升 4 要动 76 个文件（`archive_io` 在 4.x 移除），暂不升。
