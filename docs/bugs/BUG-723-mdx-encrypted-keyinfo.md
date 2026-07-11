## BUG-723 · MDX Encrypted=2 词典导入失败 empty key block info
- **报告**：2026-07-11（用户：导入 `T4jiJuk.mdx` 失败，`MDX parse error: mdx: empty key block info`）
- **真实性**：✅ 真 bug。根因 `native/hoshidicts/hoshidicts_src/mdx/mdx_reader.cpp:181`（改前）。
  该词典头部 `Encrypted="2"`（大修館 四字熟語辞典），MDX 用 MDict 自带的
  RIPEMD-128 + 滚动 XOR/半字节交换算法把已 zlib 压缩的 key-block-info 段整体
  加扰（bit 1，无需注册码即可还原）。旧 `mdx_reader` 完全无加密处理，直接把加扰
  数据喂给 `libdeflate_zlib_decompress` → 解压失败返回 `{}` →
  `key_block_info.empty()` 为真 → 抛 `mdx: empty key block info`（旧 181 行）。
  验真过程：解析头部确认 `Encrypted="2"`；用独立 Python 实现 RIPEMD-128 +
  fast_decrypt 解密该文件 key-block-info，解压得 722 字节（==头声明 decomp_size），
  解析出 9/9 个 key block、7965 条词条（==`num_entries`），证明就是加密未还原。
- **[x] ① 已修复** — `native/hoshidicts/hoshidicts_src/mdx/mdx_reader.cpp`：
  匿名命名空间新增 `ripemd128()` / `mdx_fast_decrypt()`；解析头部新增 `Encrypted`
  位域（bit 1=key-block-info 加扰，可还原；bit 0=记录块加密需注册码，不处理）；
  key-block-info 解压前，若 `encrypted & 2`，先用 `ripemd128(kbi[4..8) ++ 0x3695 LE)`
  作密钥对 `kbi[8..)` 原地还原，再走原 zlib 解压路径。提交哈希：dd85406ac。
- **[x] ② 已加自动化测试** — `native/hoshidicts/tests/mdx_encrypted_keyinfo_test.cpp`
  （CMake 注册 `mdx_encrypted_keyinfo_test`）：在内存中构造一本 `Encrypted="2"` MDX
  fixture（用独立重写的 RIPEMD-128 + 逆向 fast_decrypt 加扰），断言 `mdx_reader::parse`
  还原出 headword/definition；另加 RIPEMD-128 三个标准 KAT 向量（空串/abc/message
  digest）。逻辑闭环：fixture 解密成功 ⇒ reader 的 RIPEMD == 测试的 RIPEMD；KAT 通过
  ⇒ 测试的 RIPEMD == 规范 ⇒ reader 的 RIPEMD 规范正确。提交哈希：dd85406ac。
- **备注**：真机/端到端已在本机 Windows/MSVC 验证：链接真实 `hoshidicts.lib` 的探针对
  用户原始文件 `T4jiJuk.mdx` 解析成功（title=大修館 四字熟語辞典，entries=7965，
  词条 `あいきこつりつ` 等正确）。native 库在 app 构建时从源码编译进
  `hoshidicts_ffi.dll`/`.so`/`.dylib`，无 checked-in 预编译二进制，下次构建即生效。
  仅还原 key-block-info（bit 1）；bit 0（记录块加密、需购买注册码）仍不支持，属外部限制。
