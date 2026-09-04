// FFI 边界异常闸门的覆盖守卫。
//
// 背景（用户报告：一次性导入很多词典后，点开 app 转圈转一半自己退出、没有任何
// 报错）：`extern "C"` 不是异常边界。C++ 异常一旦从某个导出函数里逃出去，行为
// 未定义，实际就是 std::terminate → SIGABRT，**整个进程当场消失**——Dart 侧的
// try/catch、错误屏、日志落盘全都够不着，所以用户既看不到崩溃提示也拿不到日志。
// 词典越多，启动时经过 add_*_dict / lookup 的次数越多，撞上 bad_alloc 或
// filesystem_error 的概率就线性上升，于是「导入太多词典」直接表现为「打不开」。
//
// 修复是让 fushidicts_ffi.cpp 里**所有**导出无例外地经过 ffi_guard / ffi_guard_or
// / ffi_guard_void。而「所有」这个词只有被机器检查时才成立：靠人记得给新导出加
// try/catch，漏一个就等于这条修复没发生（而且漏的那次同样是静默闪退，最难查）。
// 这个测试就是那台机器——它读源码，不读行为：
//
//   * 每个 FUSHI_EXPORT 的函数体必须出现 ffi_guard*；
//   * 闸门原语本身必须还在（防「把 ffi_guard 删了但调用点还留着名字」）。
//
// 这是源码扫描守卫，不需要链接引擎，但仍走统一的 ctest 注册。
//
// Usage: ffi_guard_coverage_test  (no args) -> exit 0 PASS.
#include <cctype>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

// 源码路径由 CMake 以 FUSHI_FFI_SOURCE 传入（绝对路径），避免依赖 ctest 的 cwd。
std::string read_ffi_source() {
#ifndef FUSHI_FFI_SOURCE
  fail("FUSHI_FFI_SOURCE not defined by the build");
  return {};
#else
  const std::filesystem::path path(FUSHI_FFI_SOURCE);
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    fail("cannot open " + path.string());
    return {};
  }
  return std::string((std::istreambuf_iterator<char>(in)), {});
#endif
}

// 取 [from, to) 内是否出现 needle。
bool contains(const std::string& hay, size_t from, size_t to, const std::string& needle) {
  if (from >= hay.size()) return false;
  if (to > hay.size()) to = hay.size();
  return hay.find(needle, from) < to;
}

// 从 `pos` 起找到函数体的起始 '{'，返回其下标；找不到返回 npos。
//
// 锚点取「签名里最后一个 ')' 之后的第一个 '{'」而不是「pos 之后的第一个 '{'」：
// 参数表里出现花括号（默认值、初始化列表）会让后者命中参数表而不是函数体，
// 那样断言恒真、守卫空转。
size_t find_body_brace(const std::string& src, size_t pos) {
  const size_t paren = src.find(')', pos);
  if (paren == std::string::npos) return std::string::npos;
  return src.find('{', paren);
}

// 从函数体起始 '{' 配对到它的 '}'，返回**闭合花括号之后**的位置；不配对返回 npos。
//
// 为什么必须精确配对，而不是「从 '{' 往后取固定长度的窗口」：变异实测证明，固定
// 窗口（试过 400 字符）会越过函数结尾，命中**下一个**函数的 ffi_guard，于是把一个
// 摘掉闸门的导出判成通过——守卫全程空转还一路 PASS。搜索面必须正好是这个函数体。
//
// 字符串/字符字面量与注释里的花括号会骗过朴素配对，所以一并跳过。
size_t find_body_end(const std::string& src, size_t brace) {
  int depth = 0;
  for (size_t i = brace; i < src.size(); ++i) {
    const char c = src[i];
    if (c == '/' && i + 1 < src.size()) {
      if (src[i + 1] == '/') {
        const size_t nl = src.find('\n', i);
        if (nl == std::string::npos) return std::string::npos;
        i = nl;
        continue;
      }
      if (src[i + 1] == '*') {
        const size_t end = src.find("*/", i + 2);
        if (end == std::string::npos) return std::string::npos;
        i = end + 1;
        continue;
      }
    }
    if (c == '"' || c == '\'') {
      const char quote = c;
      ++i;
      while (i < src.size() && src[i] != quote) {
        if (src[i] == '\\') ++i;
        ++i;
      }
      continue;
    }
    if (c == '{') {
      ++depth;
    } else if (c == '}') {
      if (--depth == 0) return i + 1;
    }
  }
  return std::string::npos;
}

}  // namespace

int main() {
  const std::string src = read_ffi_source();
  if (src.empty()) {
    std::fprintf(stderr, "FAIL: empty FFI source\n");
    return 1;
  }

  // 1) 闸门原语必须存在。删掉它们而调用点还在，编译期就会炸；但删掉其中一个
  //    重载（比如只留 void 版）会让「有返回值的导出」悄悄失去 fallback 语义。
  for (const char* primitive : {"static R ffi_guard(", "static R ffi_guard_or(",
                                "static void ffi_guard_void("}) {
    if (src.find(primitive) == std::string::npos) {
      fail(std::string("missing FFI guard primitive: ") + primitive);
    }
  }

  // 2) 每个导出的函数体都必须走闸门。
  const std::string kExport = "FUSHI_EXPORT";
  std::vector<std::string> guarded;
  size_t pos = 0;
  size_t exports = 0;
  while ((pos = src.find(kExport, pos)) != std::string::npos) {
    // 跳过宏定义/注释里出现的 FUSHI_EXPORT（本文件里没有，但别让守卫脆在这上面）。
    const size_t line_start = src.rfind('\n', pos);
    const std::string line_prefix =
        src.substr(line_start == std::string::npos ? 0 : line_start + 1,
                   pos - (line_start == std::string::npos ? 0 : line_start + 1));
    if (line_prefix.find("//") != std::string::npos ||
        line_prefix.find('#') != std::string::npos) {
      pos += kExport.size();
      continue;
    }

    ++exports;
    const size_t brace = find_body_brace(src, pos + kExport.size());
    if (brace == std::string::npos) {
      fail("cannot locate function body after a FUSHI_EXPORT");
      pos += kExport.size();
      continue;
    }

    // 取函数名（签名里 '(' 之前的那个标识符）用于报错定位。
    const size_t paren = src.find('(', pos + kExport.size());
    size_t name_end = paren;
    while (name_end > 0 && (src[name_end - 1] == ' ' || src[name_end - 1] == '\n' ||
                            src[name_end - 1] == '\r')) {
      --name_end;
    }
    size_t name_start = name_end;
    while (name_start > 0 &&
           (isalnum(static_cast<unsigned char>(src[name_start - 1])) || src[name_start - 1] == '_')) {
      --name_start;
    }
    const std::string name = src.substr(name_start, name_end - name_start);

    const size_t body_end = find_body_end(src, brace);
    if (body_end == std::string::npos) {
      fail("unbalanced braces in the body of " + name);
      pos = brace;
      continue;
    }
    if (!contains(src, brace, body_end, "ffi_guard")) {
      fail("exported function does not go through the FFI guard: " + name);
    } else {
      guarded.push_back(name);
    }
    // 从函数体结尾继续扫，别让下一轮又从本函数体内部起步。
    pos = body_end;
  }

  if (exports == 0) {
    fail("found no FUSHI_EXPORT functions -- the scan anchor drifted");
  }
  // 下界防「有人把导出删到只剩两个，守卫照样绿」。当前是 23 个；只在**减少**时报警。
  if (exports < 20) {
    fail("suspiciously few exports found (" + std::to_string(exports) +
         "); the FUSHI_EXPORT anchor probably drifted");
  }

  if (g_fail == 0) {
    std::printf("PASS: all %zu exported FFI entry points go through the guard\n", exports);
    return 0;
  }
  std::fprintf(stderr, "%d check(s) failed\n", g_fail);
  return 1;
}
