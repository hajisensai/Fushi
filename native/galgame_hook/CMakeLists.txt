cmake_minimum_required(VERSION 3.14)
project(fushi_voice_hook LANGUAGES C CXX)

# galgame 一键制卡 C 阶段 —— 引擎级 voice hook 的隔离 helper 组件。
#
# 部署边界（docs/specs/galgame-mining）：injector + hook DLL 不链接进 hibiki.exe，保持独立
# 子进程/DLL。`tools/build_distribution.ps1` 单独 configure/build；校验 zip 随 Windows 主包
# 交付以支持离线首装，并同步发布到固定 release 供旧包/后台更新。
#
# 32/64 位分开构建（galgame 多为 32 位；DLL 位数必须匹配目标进程）：
#   x64: cmake -S . -B build/x64 -A x64      && cmake --build build/x64 --config Release
#   x86: cmake -S . -B build/x86 -A Win32    && cmake --build build/x86 --config Release
# 产物：fushi_voice_injector.exe + fushi_voice_hook.dll（各 arch 一份，同目录并放）；
#   诊断读取器 fushi_voice_ring_probe.exe 仅 x64 出（命名文件映射跨位数可读，reader 不注入）。

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
add_library(fushi_voice_hook SHARED
  "hook/dll_main.cpp"
  "hook/adapter.h"
  "hook/ffmpeg_runtime.h"
  "hook/hook_original_registry.h"
  "hook/tracked_handle_table.h"
  "hook/geometry_provider_registry.h"
  "hook/lookup_v19_runtime.h"
  "hook/generic_input_shield.inc"
  "hook/xaudio_resource_dispatch.h"
  "hook/bgi_arc.h"
  "hook/artemis_pfs.h"
  "hook/catsystem2_int.h"
  "hook/malie_cfi.h"
  "hook/malie_lib.h"
  "hook/qlie_pack.h"
  "hook/visual_arts_ovk.h"
  "hook/adapter_registry.inc"
  "hook/adapters/unity_adapter.inc"
  "hook/adapters/windows_audio_adapter.inc"
  "hook/adapters/siglus_adapter.inc"
  "hook/adapters/exact_lookup_signature.h"
  "hook/adapters/siglus_lookup.h"
  "hook/adapters/siglus_lookup.inc"
  "hook/adapters/bgi_ethornell_adapter.inc"
  "hook/adapters/bgi_ethornell_profile.h"
  "hook/adapters/artemis_adapter.inc"
  "hook/adapters/artemis_profile.h"
  "hook/adapters/catsystem2_adapter.inc"
  "hook/adapters/catsystem2_profile.h"
  "hook/adapters/malie_adapter.inc"
  "hook/adapters/malie_profile.h"
  "hook/adapters/qlie_adapter.inc"
  "hook/adapters/qlie_profile.h"
  "hook/adapters/kirikiri_adapter.inc"
  "hook/adapters/renpy_adapter.inc"
  "hook/adapters/text_render_adapter.inc"
  "hook/adapters/loopback_adapter.inc"
  "hook/adapters/sgre_adapter.inc"
  "hook/adapters/sgre_anchors.h"
  "hook/adapters/sgre_lookup.h"
  "hook/adapters/sgre_lookup.inc"
  "hook/adapters/sgre_profile.h"
  "hook/adapters/sgre_voice_archive.h"
  "hook/adapters/leaf_aquaplus_profile.h"
  "hook/adapters/leaf_aquaplus_lookup.h"
  "hook/adapters/leaf_aquaplus_voice_archive.h"
  "hook/adapters/leaf_aquaplus_adapter.inc"
  "hook/adapters/hunex_gge_adapter.inc"
  "hook/adapters/hunex_gge_lookup.h"
  "hook/adapters/hunex_gge_profile.h"
  "include/hunex_gge_trace.h"
  "include/generic_input_shield.h"
  "include/leaf_d3d_trace.h"
)
target_include_directories(fushi_voice_hook PRIVATE "include")
target_compile_definitions(fushi_voice_hook PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(fushi_voice_hook PRIVATE minhook winhttp ole32 bcrypt)

# Exact self-rendered engine signatures are candidate locators, never build
# identity. This synthetic gate pins global uniqueness across all executable
# sections, relocated-operand masking, decoded targets, and call boundaries on
# both helper architectures without shipping any game binary.
add_executable(fushi_exact_lookup_signature_test
  "tests/exact_lookup_signature_test.cpp"
)
target_include_directories(fushi_exact_lookup_signature_test PRIVATE
  "hook/adapters")
target_compile_definitions(fushi_exact_lookup_signature_test PRIVATE
  UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_exact_lookup_signature_test
  COMMAND fushi_exact_lookup_signature_test)

# Leaf/AQUAPLUS 锚点自推导：合成 PE 夹具（含导入表与 load config），要求推导把五处签名、
# 两个 IAT 槽与栈 cookie 全部找回来，并在不一致/不唯一/跨引擎场景下拒绝认领。
# 游戏二进制不入库，跨构建正确性只能靠这种结构夹具 + 真机自检来钉。
add_executable(fushi_leaf_autoprofile_test
  "tests/leaf_autoprofile_test.cpp"
)
target_include_directories(fushi_leaf_autoprofile_test PRIVATE
  "hook/adapters")
target_compile_definitions(fushi_leaf_autoprofile_test PRIVATE
  UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_leaf_autoprofile_test
  COMMAND fushi_leaf_autoprofile_test)

# Siglus OVK 索引/Ogg 完整性解析是纯函数，独立小测试不需启动或注入游戏。
enable_testing()
add_executable(fushi_siglus_ovk_test
  "tests/siglus_ovk_test.cpp"
)
target_include_directories(fushi_siglus_ovk_test PRIVATE "hook")
add_test(NAME fushi_siglus_ovk_test COMMAND fushi_siglus_ovk_test)

# HUNEX story renderer callback-to-worker hand-off. The focused test exercises
# only synthetic glyph/index/rectangle values and contains no game payload.
add_executable(fushi_hunex_gge_capture_bridge_test
  "tests/hunex_gge_capture_bridge_test.cpp"
)
target_include_directories(fushi_hunex_gge_capture_bridge_test PRIVATE
  "hook/adapters")
add_test(NAME fushi_hunex_gge_capture_bridge_test
  COMMAND fushi_hunex_gge_capture_bridge_test)

# HUNEX HFA/HW directory, wrapper and Ogg validation are worker-side pure
# functions. The focused test uses only synthetic bytes and never game data.
add_executable(fushi_hunex_gge_adapter_test
  "tests/hunex_gge_adapter_test.cpp"
)
target_include_directories(fushi_hunex_gge_adapter_test PRIVATE "hook")
add_test(NAME fushi_hunex_gge_adapter_test
  COMMAND fushi_hunex_gge_adapter_test)

add_executable(fushi_hunex_gge_lookup_test
  "tests/hunex_gge_lookup_test.cpp"
)
target_include_directories(fushi_hunex_gge_lookup_test PRIVATE
  "hook/adapters")
add_test(NAME fushi_hunex_gge_lookup_test
  COMMAND fushi_hunex_gge_lookup_test)

add_executable(fushi_siglus_text_test
  "tests/siglus_text_test.cpp"
)
target_include_directories(fushi_siglus_text_test PRIVATE "hook")
add_test(NAME fushi_siglus_text_test COMMAND fushi_siglus_text_test)

add_executable(fushi_siglus_lookup_test
  "tests/siglus_lookup_test.cpp"
)
target_include_directories(fushi_siglus_lookup_test PRIVATE "hook")
add_test(NAME fushi_siglus_lookup_test COMMAND fushi_siglus_lookup_test)

add_executable(fushi_leaf_aquaplus_adapter_test
  "tests/leaf_aquaplus_adapter_test.cpp"
)
target_include_directories(fushi_leaf_aquaplus_adapter_test PRIVATE "hook")
add_test(NAME fushi_leaf_aquaplus_adapter_test
  COMMAND fushi_leaf_aquaplus_adapter_test)

add_executable(fushi_leaf_aquaplus_voice_archive_test
  "tests/leaf_aquaplus_voice_archive_test.cpp"
)
target_include_directories(fushi_leaf_aquaplus_voice_archive_test
  PRIVATE "hook/adapters")
add_test(NAME fushi_leaf_aquaplus_voice_archive_test
  COMMAND fushi_leaf_aquaplus_voice_archive_test)

add_executable(fushi_resource_audio_ready_test
  "tests/resource_audio_ready_test.cpp"
)
target_include_directories(fushi_resource_audio_ready_test PRIVATE "include")
target_compile_definitions(fushi_resource_audio_ready_test PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_resource_audio_ready_test COMMAND fushi_resource_audio_ready_test)

add_executable(fushi_utterance_window_test
  "tests/utterance_window_test.cpp"
)
target_include_directories(fushi_utterance_window_test PRIVATE "include")
add_test(NAME fushi_utterance_window_test COMMAND fushi_utterance_window_test)

add_executable(fushi_voice_clip_energy_test
  "tests/voice_clip_energy_test.cpp"
)
target_include_directories(fushi_voice_clip_energy_test PRIVATE "include")
add_test(NAME fushi_voice_clip_energy_test COMMAND fushi_voice_clip_energy_test)

add_executable(fushi_xaudio_source_format_test
  "tests/xaudio_source_format_test.cpp"
)
target_include_directories(fushi_xaudio_source_format_test PRIVATE "hook" "include")
target_compile_definitions(fushi_xaudio_source_format_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_xaudio_source_format_test
  COMMAND fushi_xaudio_source_format_test)

add_executable(fushi_hook_original_registry_test
  "tests/hook_original_registry_test.cpp"
)
target_include_directories(fushi_hook_original_registry_test PRIVATE "hook")
add_test(NAME fushi_hook_original_registry_test
  COMMAND fushi_hook_original_registry_test)

add_executable(fushi_tracked_handle_table_test
  "tests/tracked_handle_table_test.cpp"
)
target_include_directories(fushi_tracked_handle_table_test PRIVATE "hook")
target_compile_definitions(fushi_tracked_handle_table_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_tracked_handle_table_test
  COMMAND fushi_tracked_handle_table_test)

add_executable(fushi_xaudio_trace_export_test
  "tests/xaudio_trace_export_test.cpp"
)
target_include_directories(fushi_xaudio_trace_export_test PRIVATE "include")
target_compile_definitions(fushi_xaudio_trace_export_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_dependencies(fushi_xaudio_trace_export_test fushi_voice_hook)
add_test(NAME fushi_xaudio_trace_export_test
  COMMAND fushi_xaudio_trace_export_test "$<TARGET_FILE:fushi_voice_hook>")

add_executable(fushi_leaf_d3d_trace_export_test
  "tests/leaf_d3d_trace_export_test.cpp"
)
target_include_directories(fushi_leaf_d3d_trace_export_test PRIVATE "include")
target_compile_definitions(fushi_leaf_d3d_trace_export_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_dependencies(fushi_leaf_d3d_trace_export_test fushi_voice_hook)
add_test(NAME fushi_leaf_d3d_trace_export_test
  COMMAND fushi_leaf_d3d_trace_export_test "$<TARGET_FILE:fushi_voice_hook>")

add_executable(fushi_voice_resource_filename_test
  "tests/voice_resource_filename_test.cpp"
)
target_include_directories(fushi_voice_resource_filename_test PRIVATE "hook")
add_test(NAME fushi_voice_resource_filename_test COMMAND fushi_voice_resource_filename_test)

# KiriKiri 资源流「是不是语音」判据（tenshi_sz 真机：SE/BGM/脚本误当语音）。纯函数头，双架构同跑。
add_executable(fushi_kirikiri_voice_storage_name_test
  "tests/kirikiri_voice_storage_name_test.cpp"
)
target_include_directories(fushi_kirikiri_voice_storage_name_test PRIVATE "hook")
add_test(NAME fushi_kirikiri_voice_storage_name_test
  COMMAND fushi_kirikiri_voice_storage_name_test)

# 查词整句 ↔ 文本道行的同句判据（点击载荷 text_generation 反查，BUG-2130 家族）。
add_executable(fushi_lookup_line_text_match_test
  "tests/lookup_line_text_match_test.cpp"
)
target_include_directories(fushi_lookup_line_text_match_test PRIVATE "hook")
add_test(NAME fushi_lookup_line_text_match_test
  COMMAND fushi_lookup_line_text_match_test)

add_executable(fushi_qlie_pack_test
  "tests/qlie_pack_test.cpp"
)
target_include_directories(fushi_qlie_pack_test PRIVATE "hook")
add_test(NAME fushi_qlie_pack_test COMMAND fushi_qlie_pack_test)

add_executable(fushi_ffmpeg_runtime_test
  "tests/ffmpeg_runtime_test.cpp"
)
target_include_directories(fushi_ffmpeg_runtime_test PRIVATE "hook")
add_test(NAME fushi_ffmpeg_runtime_test COMMAND fushi_ffmpeg_runtime_test)

add_executable(fushi_child_process_policy_test
  "tests/child_process_policy_test.cpp"
)
target_include_directories(fushi_child_process_policy_test PRIVATE "injector")
add_test(NAME fushi_child_process_policy_test COMMAND fushi_child_process_policy_test)

# injector 重连同一游戏进程时必须复用 DLL 持有的映射，不能把 hooked/text/audio 环清零。
add_executable(fushi_voice_session_reuse_test
  "tests/session_reuse_test.cpp"
)
target_include_directories(fushi_voice_session_reuse_test PRIVATE "include")
target_compile_definitions(fushi_voice_session_reuse_test PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_voice_session_reuse_test COMMAND fushi_voice_session_reuse_test)

# ready 旧映射的 resident DLL 身份门：不启动/注入游戏，只验证路径与摘要的 fail-closed
# 判定。Fushi 更新后旧 DLL 仍驻留时，injector 不得再误报 reuse_ready。
# 同时带一条**调用侧**源码扫描守卫（FUSHI_INJECTOR_MAIN_SOURCE）：纯函数判据再对，只要
# 调用方把两侧摘要都从磁盘读，kDigestMismatch 就恒不可达 —— 那种退化纯函数测试测不到。
add_executable(fushi_hook_module_identity_test
  "tests/hook_module_identity_test.cpp"
)
target_include_directories(fushi_hook_module_identity_test PRIVATE "include")
target_compile_definitions(fushi_hook_module_identity_test PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN
  "FUSHI_INJECTOR_MAIN_SOURCE=\"${CMAKE_CURRENT_SOURCE_DIR}/injector/injector_main.cpp\"")
add_test(NAME fushi_hook_module_identity_test COMMAND fushi_hook_module_identity_test)

# v16 injected WASAPI loopback policy: pure ABI/publication/lifecycle reducer
# coverage. It never opens an audio endpoint or starts a game and runs in both
# Win32/x64 configurations.
add_executable(fushi_native_loopback_policy_test
  "tests/native_loopback_policy_test.cpp"
)
target_include_directories(fushi_native_loopback_policy_test PRIVATE "include")
target_compile_definitions(fushi_native_loopback_policy_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_native_loopback_policy_test
  COMMAND fushi_native_loopback_policy_test)

add_executable(fushi_voice_hook_ipc_name_test
  "tests/voice_hook_ipc_name_test.cpp"
)
target_include_directories(fushi_voice_hook_ipc_name_test PRIVATE "include")
target_compile_definitions(fushi_voice_hook_ipc_name_test PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_voice_hook_ipc_name_test COMMAND fushi_voice_hook_ipc_name_test)

add_executable(fushi_unity_event_cursor_test
  "tests/unity_event_cursor_test.cpp"
)
target_include_directories(fushi_unity_event_cursor_test PRIVATE "include")
add_test(NAME fushi_unity_event_cursor_test COMMAND fushi_unity_event_cursor_test)

# IL2CPP 托管线程 attach 守卫（根因回归：未注册线程分配触发 Boehm GC 崩溃）。纯逻辑，按
# 函数指针注入假 IL2CPP 线程 API，不需真实 GameAssembly.dll。
add_executable(fushi_il2cpp_thread_scope_test
  "tests/il2cpp_thread_scope_test.cpp"
)
target_include_directories(fushi_il2cpp_thread_scope_test PRIVATE "hook")
add_test(NAME fushi_il2cpp_thread_scope_test COMMAND fushi_il2cpp_thread_scope_test)

add_executable(fushi_steam_launch_test
  "tests/steam_launch_test.cpp"
)
target_include_directories(fushi_steam_launch_test PRIVATE "include")
add_test(NAME fushi_steam_launch_test COMMAND fushi_steam_launch_test)

add_executable(fushi_locale_emulator_launch_test
  "tests/locale_emulator_launch_test.cpp"
)
target_include_directories(fushi_locale_emulator_launch_test PRIVATE "injector")
target_compile_definitions(fushi_locale_emulator_launch_test PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_locale_emulator_launch_test COMMAND fushi_locale_emulator_launch_test)

# 启动失败处置策略（根因回归：Resume 前失败会留下永久挂起的游戏进程）。纯逻辑。
add_executable(fushi_launch_failure_policy_test
  "tests/launch_failure_policy_test.cpp"
)
target_include_directories(fushi_launch_failure_policy_test PRIVATE "include")
add_test(NAME fushi_launch_failure_policy_test COMMAND fushi_launch_failure_policy_test)

# launch 命令行组装（根因回归：含空格/引号的 --arg 在游戏侧被拆成多个 argv）。
# 断言逐字节输出 + 真过 CommandLineToArgvW 反解。
add_executable(fushi_launch_command_line_test
  "tests/launch_command_line_test.cpp"
)
target_include_directories(fushi_launch_command_line_test PRIVATE "include")
target_compile_definitions(fushi_launch_command_line_test PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(fushi_launch_command_line_test PRIVATE shell32)
add_test(NAME fushi_launch_command_line_test COMMAND fushi_launch_command_line_test)

# Siglus 文件夹签名识别（根因回归：改名 Siglus exe 被早注入弹掉）。纯逻辑，注入假文件表。
add_executable(fushi_siglus_launch_test
  "tests/siglus_launch_test.cpp"
)
target_include_directories(fushi_siglus_launch_test PRIVATE "include")
add_test(NAME fushi_siglus_launch_test COMMAND fushi_siglus_launch_test)

# 启动器布局识别（根因回归：AngelBeats 体験版的引擎签名在 StartData/gamedata 下，
# 只看被启动 exe 自己那层就把 hook 下在了转手即退的启动器上）。纯逻辑，注入假目录树。
add_executable(fushi_launcher_layout_test
  "tests/launcher_layout_test.cpp"
)
target_include_directories(fushi_launcher_layout_test PRIVATE "include")
add_test(NAME fushi_launcher_layout_test COMMAND fushi_launcher_layout_test)

# 游戏主窗口判据（真 Win32 窗口：VCL 隐藏 owner 形状必选中，BUG-2121）。
add_executable(fushi_game_main_window_test
  "tests/game_main_window_test.cpp"
)
target_include_directories(fushi_game_main_window_test PRIVATE "hook")
add_test(NAME fushi_game_main_window_test
  COMMAND fushi_game_main_window_test)

# 第三条 exporter 路径的判据（形状门用真内存 + VirtualQuery 验；BUG-2145）。
add_executable(fushi_kirikiri_exporter_scan_test
  "tests/kirikiri_exporter_scan_test.cpp"
)
target_include_directories(fushi_kirikiri_exporter_scan_test PRIVATE "hook" "include")
add_test(NAME fushi_kirikiri_exporter_scan_test
  COMMAND fushi_kirikiri_exporter_scan_test)

# 通用位图呈现器的几何换算（卡片飘出游戏窗口 == 用户看不见卡片，与"没投帧"同形）。
add_executable(fushi_lookup_overlay_geometry_test
  "tests/lookup_overlay_geometry_test.cpp"
)
target_include_directories(fushi_lookup_overlay_geometry_test PRIVATE "include")
add_test(NAME fushi_lookup_overlay_geometry_test
  COMMAND fushi_lookup_overlay_geometry_test)

# KiriKiri 二进制级延迟附着 profile（根因回归：恋爱成双早注入触发 Access Violation）。
add_executable(fushi_kirikiri_launch_profile_test
  "tests/kirikiri_launch_profile_test.cpp"
)
target_include_directories(fushi_kirikiri_launch_profile_test PRIVATE "include")
add_test(NAME fushi_kirikiri_launch_profile_test
  COMMAND fushi_kirikiri_launch_profile_test)

add_executable(fushi_luna_hook_config_test tests/luna_hook_config_test.cpp)
target_include_directories(fushi_luna_hook_config_test PRIVATE include)
add_test(NAME fushi_luna_hook_config_test COMMAND fushi_luna_hook_config_test)

add_executable(fushi_luna_bridge_abi_test tests/luna_bridge_abi_test.cpp)
target_include_directories(fushi_luna_bridge_abi_test PRIVATE include)
target_compile_definitions(fushi_luna_bridge_abi_test PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_luna_bridge_abi_test COMMAND fushi_luna_bridge_abi_test)

add_executable(fushi_luna_text_replay_test tests/luna_text_replay_test.cpp)
target_include_directories(fushi_luna_text_replay_test PRIVATE include)
add_test(NAME fushi_luna_text_replay_test COMMAND fushi_luna_text_replay_test
  "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/luna_thread_selection.tsv")

add_executable(fushi_thread_preview_ipc_test
  tests/thread_preview_ipc_test.cpp)
target_include_directories(fushi_thread_preview_ipc_test PRIVATE include)
target_compile_definitions(fushi_thread_preview_ipc_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_thread_preview_ipc_test
  COMMAND fushi_thread_preview_ipc_test)

add_executable(fushi_text_lane_ipc_test
  tests/text_lane_ipc_test.cpp)
target_include_directories(fushi_text_lane_ipc_test PRIVATE include)
target_compile_definitions(fushi_text_lane_ipc_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_text_lane_ipc_test
  COMMAND fushi_text_lane_ipc_test)

add_executable(fushi_hunex_gge_selected_text_test
  tests/hunex_gge_selected_text_test.cpp)
target_include_directories(fushi_hunex_gge_selected_text_test
  PRIVATE "hook/adapters" "include")
target_compile_definitions(fushi_hunex_gge_selected_text_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_hunex_gge_selected_text_test
  COMMAND fushi_hunex_gge_selected_text_test)

# v14 游戏内查词区的契约级测试：各子区不重叠/不越界/8 对齐、IsLookupFrameSane 的每条
# 拒绝理由、旧会话给 nullptr 而非野指针、以及"v14 是纯追加"这条不变量。
add_executable(fushi_lookup_ipc_contract_test
  tests/lookup_ipc_contract_test.cpp)
target_include_directories(fushi_lookup_ipc_contract_test PRIVATE include)
target_compile_definitions(fushi_lookup_ipc_contract_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_lookup_ipc_contract_test
  COMMAND fushi_lookup_ipc_contract_test)

add_executable(fushi_geometry_provider_registry_test
  tests/geometry_provider_registry_test.cpp)
target_include_directories(fushi_geometry_provider_registry_test PRIVATE
  include
  hook)
target_compile_definitions(fushi_geometry_provider_registry_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_geometry_provider_registry_test
  COMMAND fushi_geometry_provider_registry_test)

# 游戏内查词的会话 replay：hit→frame→apply、旧帧丢弃、未开启零写入、卡片外输入不转发、
# 会话结束清理不串数据。fixture 走 argv（与 fushi_luna_text_replay_test 同一路子）。
add_executable(fushi_lookup_session_replay_test
  tests/lookup_session_replay_test.cpp)
target_include_directories(fushi_lookup_session_replay_test PRIVATE include)
target_compile_definitions(fushi_lookup_session_replay_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_lookup_session_replay_test
  COMMAND fushi_lookup_session_replay_test
  "${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures/kirikiri_lookup_replay.tsv")

# v19 generic bare-left-click shield reducers: complete down/up/tail ownership,
# non-left byte isolation, standard DIMOUSESTATE layouts, stable buffered
# compaction and Raw Input flag preservation. Pure synthetic data; no device.
add_executable(fushi_generic_input_shield_test
  tests/generic_input_shield_test.cpp)
target_include_directories(fushi_generic_input_shield_test PRIVATE include)
target_compile_definitions(fushi_generic_input_shield_test PRIVATE
  "FUSHI_NATIVE_SOURCE_DIR=\"${CMAKE_CURRENT_SOURCE_DIR}\"")
add_test(NAME fushi_generic_input_shield_test
  COMMAND fushi_generic_input_shield_test)

add_executable(fushi_unity_text_mesh_reassembler_test
  tests/unity_text_mesh_reassembler_test.cpp)
target_include_directories(fushi_unity_text_mesh_reassembler_test
  PRIVATE include)
target_compile_definitions(fushi_unity_text_mesh_reassembler_test
  PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_unity_text_mesh_reassembler_test
  COMMAND fushi_unity_text_mesh_reassembler_test)

add_executable(fushi_adapter_contract_test tests/adapter_contract_test.cpp)
# v19 起 adapter.h 依赖 IPC 头（LookupAdmissionReport 是 adapter 契约的一部分：
# adapter 要回答"本引擎的查词准入结论"，而那个结论的类型定义在跨进程契约里）。
target_include_directories(fushi_adapter_contract_test PRIVATE hook include)
add_test(NAME fushi_adapter_contract_test COMMAND fushi_adapter_contract_test)

# 「模块表稳定了吗」的判据（hook/module_settle.h）。纯头、零 Win32 依赖，所以
# 能被 CTest 单独包含——adapter_registry.inc 依赖 dll_main 的全局与 MinHook，
# 永远无法单测，而这条收敛规则恰恰是查词准入误报的根因所在。
add_executable(fushi_module_settle_test tests/module_settle_test.cpp)
target_include_directories(fushi_module_settle_test PRIVATE hook include)
add_test(NAME fushi_module_settle_test COMMAND fushi_module_settle_test)

# 宿主 exe 摘要共享槽（hook/host_executable_digest.h）。同样是纯头，钉住"一次性写入"
# 和"算不出发空串、不发一串零"这两条——摘要是准入判成不支持时用户唯一能报上来的信息。
add_executable(fushi_host_executable_digest_test
  tests/host_executable_digest_test.cpp)
target_include_directories(fushi_host_executable_digest_test PRIVATE hook include)
add_test(NAME fushi_host_executable_digest_test
  COMMAND fushi_host_executable_digest_test)

add_executable(fushi_directsound_format_registry_test
  tests/directsound_format_registry_test.cpp)
target_include_directories(fushi_directsound_format_registry_test PRIVATE hook)
add_test(NAME fushi_directsound_format_registry_test
  COMMAND fushi_directsound_format_registry_test)

# 注入器（Hibiki 主进程把它当子进程拉起）。attach（--pid）+ launch（--launch；通常
# CREATE_SUSPENDED 早注入，Siglus/Enigma 自动延迟附着）两种模式，各 arch 一份。
add_executable(fushi_voice_injector
  "injector/injector_main.cpp"
  "injector/child_process_policy.h"
  "injector/locale_emulator_launch.h"
)
target_include_directories(fushi_voice_injector PRIVATE "include" "hook" "injector")
target_compile_definitions(fushi_voice_injector PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(fushi_voice_injector PRIVATE shell32 bcrypt)

# CLI-only preflight contract. The script launches only the injector itself
# with --capabilities/invalid policy and never opens or creates a game process.
add_test(NAME fushi_native_loopback_cli_contract_test
  COMMAND ${CMAKE_COMMAND}
    "-DINJECTOR=$<TARGET_FILE:fushi_voice_injector>"
    -P "${CMAKE_CURRENT_SOURCE_DIR}/tests/native_loopback_cli_contract_test.cmake")

# Unity IL2CPP Streaming AudioClip 资源提取器（仅 x64 Unity 游戏需要）。它在 injector
# 宿主进程解析 AssetBundle，并调用开源 vgmstream 解码 FSB5；游戏内 DLL 只写资源事件。
# 依赖按固定 release + SHA256 获取到 build staging，不把第三方二进制提交进仓库。
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
  find_program(DOTNET_EXECUTABLE dotnet REQUIRED)
  find_program(POWERSHELL_EXECUTABLE powershell REQUIRED)
  set(_UNITY_AUDIO_PROJECT
      "${CMAKE_CURRENT_SOURCE_DIR}/unity_audio_extract/Fushi.UnityAudioExtract.csproj")
  set(_UNITY_AUDIO_RUNTIME "${CMAKE_CURRENT_BINARY_DIR}/unity_audio_runtime")
  add_custom_target(fushi_unity_audio_runtime ALL
    COMMAND "${POWERSHELL_EXECUTABLE}" -NoProfile -ExecutionPolicy Bypass
      -File "${CMAKE_CURRENT_SOURCE_DIR}/unity_audio_extract/fetch_runtime.ps1"
      -RuntimeDir "${_UNITY_AUDIO_RUNTIME}"
    COMMAND "${DOTNET_EXECUTABLE}" publish "${_UNITY_AUDIO_PROJECT}"
      --configuration Release --runtime win-x64 --self-contained true
      -p:PublishSingleFile=true -p:PublishTrimmed=false
      --output "${_UNITY_AUDIO_RUNTIME}"
    DEPENDS
      "${_UNITY_AUDIO_PROJECT}"
      "${CMAKE_CURRENT_SOURCE_DIR}/unity_audio_extract/Program.cs"
      "${CMAKE_CURRENT_SOURCE_DIR}/unity_audio_extract/fetch_runtime.ps1"
    COMMENT "构建 Unity Streaming AudioClip 资源提取运行时"
    VERBATIM)
  add_dependencies(fushi_voice_injector fushi_unity_audio_runtime)
  add_custom_command(TARGET fushi_voice_injector POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
      "${_UNITY_AUDIO_RUNTIME}"
      "$<TARGET_FILE_DIR:fushi_voice_injector>/unity_audio_runtime"
    COMMENT "部署 Unity 音频资源提取器到 injector 隔离目录"
    VERBATIM)
endif()

# 环形缓冲诊断读取器（只读共享内存，不注入）。命名文件映射跨 32/64 位可读，故只出 x64 一份即
# 可读任意位数游戏里 hook 填的缓冲——仅在 64 位构建时加入本目标（x86 配置跳过）。
if(CMAKE_SIZEOF_VOID_P EQUAL 8)
  add_executable(fushi_voice_ring_probe
    "tools/ring_probe.cpp"
  )
  target_include_directories(fushi_voice_ring_probe PRIVATE "include")
  target_compile_definitions(fushi_voice_ring_probe PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)

  # 游戏内查词诊断读取器。与 ring probe 同理由只出 x64。它是唯一会写共享内存的诊断工具，
  # 但只写 `lookup_enabled` 这一个 host→hook 开关（契约里本就归 host 写），目的是把注入侧
  # 的传感器单独拎出来验——否则「传感器没装」与「host 没投帧」在现象上完全同形。
  add_executable(fushi_voice_lookup_probe
    "tools/lookup_probe.cpp"
  )
  target_include_directories(fushi_voice_lookup_probe PRIVATE "include")
  target_compile_definitions(fushi_voice_lookup_probe PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

# LunaHost 符号解析校验器（纯查符号，不注入、不跑游戏）。x64/x86 各出一份，运行期从自身目录
# 找同位数 LunaHost<arch>.dll 校验导出。CI/本地构建后可直接跑它离线确认 ABI 契约满足。
add_executable(fushi_luna_symcheck
  "tools/luna_symcheck.cpp"
)
target_include_directories(fushi_luna_symcheck PRIVATE "include")
target_compile_definitions(fushi_luna_symcheck PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
add_test(NAME fushi_luna_symcheck COMMAND fushi_luna_symcheck)

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
  add_custom_command(TARGET fushi_voice_injector POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
      "${_LUNA_SRC}/${_luna_dll}"
      "$<TARGET_FILE_DIR:fushi_voice_injector>/${_luna_dll}"
    COMMENT "部署 vendored LunaHook 二进制 ${_luna_dll} 到 injector 目录"
    VERBATIM)
endforeach()
add_dependencies(fushi_luna_symcheck fushi_voice_injector)
add_executable(fushi_reallive_adapter_test "tests/reallive_adapter_test.cpp")
target_include_directories(fushi_reallive_adapter_test PRIVATE "hook")
add_test(NAME fushi_reallive_adapter_test COMMAND fushi_reallive_adapter_test)
add_executable(fushi_elf_ai6_adapter_test "tests/elf_ai6_adapter_test.cpp")
target_include_directories(fushi_elf_ai6_adapter_test PRIVATE "hook")
add_test(NAME fushi_elf_ai6_adapter_test COMMAND fushi_elf_ai6_adapter_test)
add_executable(fushi_sgre_adapter_test "tests/sgre_adapter_test.cpp")
target_include_directories(fushi_sgre_adapter_test PRIVATE "hook" "include")
target_compile_definitions(fushi_sgre_adapter_test PRIVATE
  UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
target_link_libraries(fushi_sgre_adapter_test PRIVATE bcrypt)
add_test(NAME fushi_sgre_adapter_test COMMAND fushi_sgre_adapter_test)
# BUG-2136 层原点：纯像素求解（host 侧算法，与 host_executable_digest 同一范式——
# 需要被测的 host 逻辑放 include/，runner 用相对路径 include 真相源）。
add_executable(fushi_layer_origin_pixels_test
  "tests/layer_origin_pixels_test.cpp")
target_include_directories(fushi_layer_origin_pixels_test PRIVATE include)
add_test(NAME fushi_layer_origin_pixels_test
  COMMAND fushi_layer_origin_pixels_test)

add_executable(fushi_cmvs_adapter_test "tests/cmvs_adapter_test.cpp")
target_include_directories(fushi_cmvs_adapter_test PRIVATE "hook")
add_test(NAME fushi_cmvs_adapter_test COMMAND fushi_cmvs_adapter_test)
add_executable(fushi_unreal_iostore_adapter_test "tests/unreal_iostore_adapter_test.cpp")
target_include_directories(fushi_unreal_iostore_adapter_test PRIVATE "hook" "include")
add_test(NAME fushi_unreal_iostore_adapter_test COMMAND fushi_unreal_iostore_adapter_test)

add_executable(fushi_aos_sfa_adapter_test "tests/aos_sfa_adapter_test.cpp")
target_include_directories(fushi_aos_sfa_adapter_test PRIVATE "hook")
add_test(NAME fushi_aos_sfa_adapter_test COMMAND fushi_aos_sfa_adapter_test)
add_executable(fushi_unity_mono_adapter_test "tests/unity_mono_adapter_test.cpp")
target_include_directories(fushi_unity_mono_adapter_test PRIVATE "hook")
add_test(NAME fushi_unity_mono_adapter_test COMMAND fushi_unity_mono_adapter_test)

add_executable(fushi_engine_identity_layout_test
  "tests/engine_identity_layout_test.cpp")
target_include_directories(fushi_engine_identity_layout_test PRIVATE "hook")
add_test(NAME fushi_engine_identity_layout_test
  COMMAND fushi_engine_identity_layout_test)

add_executable(fushi_smash_fzmedia_adapter_test "tests/smash_fzmedia_adapter_test.cpp")
target_include_directories(fushi_smash_fzmedia_adapter_test PRIVATE "hook")
add_test(NAME fushi_smash_fzmedia_adapter_test COMMAND fushi_smash_fzmedia_adapter_test)

# smash/fzmedia lookup runtime decision logic (Win32-free core header): layer
# line request, host origin epoch gating, client-rect readiness gate, hit
# mapping, subclass message decision table and shield mask reducer.
add_executable(fushi_smash_fzmedia_lookup_test
  "tests/smash_fzmedia_lookup_test.cpp"
)
target_include_directories(fushi_smash_fzmedia_lookup_test PRIVATE
  "hook/adapters")
add_test(NAME fushi_smash_fzmedia_lookup_test
  COMMAND fushi_smash_fzmedia_lookup_test)
