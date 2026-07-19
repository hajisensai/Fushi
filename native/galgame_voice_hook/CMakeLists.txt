cmake_minimum_required(VERSION 3.14)
project(hibiki_voice_hook LANGUAGES C CXX)

# galgame 一键制卡 C 阶段 —— 引擎级 voice hook 的**独立可选 helper 组件**。
#
# 部署红线（docs/specs/galgame-mining）：这套 injector + hook DLL 与 hibiki.exe **物理隔离、
# 分离构建/分发**。注入用的 CreateRemoteThread/WriteProcessMemory 必被杀软启发式报毒，编进主
# 程序会污染整个 app 的分发口碑；隔离成独立组件把污染面锁死在这里。**故本 CMake 不被
# hibiki/windows 引用**，单独 configure/build，产物按需下载分发。
#
# 32/64 位分开构建（galgame 多为 32 位；DLL 位数必须匹配目标进程）：
#   x64: cmake -S . -B build/x64 -A x64      && cmake --build build/x64 --config Release
#   x86: cmake -S . -B build/x86 -A Win32    && cmake --build build/x86 --config Release
# 产物：hibiki_voice_injector.exe + hibiki_voice_hook.dll（各 arch 一份，同目录并放）；
#   诊断读取器 hibiki_voice_ring_probe.exe 仅 x64 出（命名文件映射跨位数可读，reader 不注入）。

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 源码含中文注释/字符串（UTF-8 无 BOM）。中文 locale 下 MSVC 默认按 GBK 解析会把 UTF-8
# 多字节序列误读、错乱引号/大括号（本组件即因此曾编译失败）。/utf-8 明确按 UTF-8 解析。
if(MSVC)
  add_compile_options(/utf-8)
endif()

# MinHook（vendored，MIT，与本组件 GPLv3 兼容）—— inline/vtable hook 引擎（C.2 用）。
#
# 直接手动列出 MinHook 的 C 源码建 static 目标，**不 add_subdirectory 它自带的 CMake**：
# 上游 CMakeLists 声明 `cmake_minimum_required(VERSION 3.0...3.5)`，CMake 4.x 已移除对
# < 3.5 的兼容会致命报错；手动列源码同样可复现，且避开它的 install/export 逻辑。
# hde32.c / hde64.c 各自按 _M_X64 / _M_IX86 编译期自我 gating，两个都列进来无冲突。
add_library(minhook STATIC
  "third_party/minhook/src/buffer.c"
  "third_party/minhook/src/hook.c"
  "third_party/minhook/src/trampoline.c"
  "third_party/minhook/src/hde/hde32.c"
  "third_party/minhook/src/hde/hde64.c"
)
target_include_directories(minhook PUBLIC "third_party/minhook/include")

# 注入进游戏的 hook DLL。
add_library(hibiki_voice_hook SHARED
  "hook/dll_main.cpp"
)
target_include_directories(hibiki_voice_hook PRIVATE "include")
target_compile_definitions(hibiki_voice_hook PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(hibiki_voice_hook PRIVATE minhook)

# Siglus OVK 索引/Ogg 完整性解析是纯函数，独立小测试不需启动或注入游戏。
enable_testing()
add_executable(hibiki_siglus_ovk_test
  "tests/siglus_ovk_test.cpp"
)
target_include_directories(hibiki_siglus_ovk_test PRIVATE "hook")
add_test(NAME hibiki_siglus_ovk_test COMMAND hibiki_siglus_ovk_test)

# 注入器（Hibiki 主进程把它当子进程拉起）。attach（--pid）+ launch（--launch；通常
# CREATE_SUSPENDED 早注入，Siglus/Enigma 自动延迟附着）两种模式，各 arch 一份。
add_executable(hibiki_voice_injector
  "injector/injector_main.cpp"
)
target_include_directories(hibiki_voice_injector PRIVATE "include")
target_compile_definitions(hibiki_voice_injector PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(hibiki_voice_injector PRIVATE shell32)

# 环形缓冲诊断读取器（只读共享内存，不注入）。命名文件映射跨 32/64 位可读，故只出 x64 一份即
# 可读任意位数游戏里 hook 填的缓冲——仅在 64 位构建时加入本目标（x86 配置跳过）。
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
  add_executable(hibiki_voice_ring_probe
    "tools/ring_probe.cpp"
  )
  target_include_directories(hibiki_voice_ring_probe PRIVATE "include")
  target_compile_definitions(hibiki_voice_ring_probe PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

# LunaHost 符号解析校验器（纯查符号，不注入、不跑游戏）。x64/x86 各出一份，运行期从自身目录
# 找同位数 LunaHost<arch>.dll 校验导出。CI/本地构建后可直接跑它离线确认 ABI 契约满足。
add_executable(hibiki_luna_symcheck
  "tools/luna_symcheck.cpp"
)
target_include_directories(hibiki_luna_symcheck PRIVATE "include")
target_compile_definitions(hibiki_luna_symcheck PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)

# LunaHook 的 vendored 二进制（GPLv3，third_party/lunahook/，动态加载不链 .lib）。构建后把与本
# 编译位数匹配的 LunaHost<arch>.dll（injector 加载）+ LunaHook<arch>.dll（注入进游戏）拷到
# injector 输出目录，使 injector 运行期在自身目录就能找到它们。位数由 CMAKE_SIZEOF_VOID_P 决定。
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
  set(_LUNA_ARCH "64")
else()
  set(_LUNA_ARCH "32")
endif()
set(_LUNA_SRC "${CMAKE_CURRENT_SOURCE_DIR}/third_party/lunahook")
foreach(_luna_dll "LunaHost${_LUNA_ARCH}.dll" "LunaHook${_LUNA_ARCH}.dll")
  add_custom_command(TARGET hibiki_voice_injector POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${_LUNA_SRC}/${_luna_dll}"
      "$<TARGET_FILE_DIR:hibiki_voice_injector>/${_luna_dll}"
    COMMENT "部署 vendored LunaHook 二进制 ${_luna_dll} 到 injector 目录"
    VERBATIM)
endforeach()
