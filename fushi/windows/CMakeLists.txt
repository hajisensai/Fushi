cmake_minimum_required(VERSION 3.14)
project(fushi LANGUAGES C CXX)

set(BINARY_NAME "fushi")

cmake_policy(SET CMP0063 NEW)

set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Configure build options.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()

set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Force UTF-8 source encoding for all targets (including plugins) to avoid
# C4819 warnings on CJK Windows systems where the default code page cannot
# represent characters in third-party plugin sources.
add_compile_options(/utf-8)

# GitHub's windows-latest image rolled forward to VS 2026 / MSVC 14.51, whose
# updated STL turned the <experimental/coroutine> deprecation (STL1011) from a
# warning into a hard static_assert. The forked flutter_inappwebview_windows
# plugin (via <winrt/base.h> / WIL) and the upstream permission_handler_windows
# plugin still pull that header in, so both fail to compile under the new
# toolchain even though our code is unchanged. Define the silencer Microsoft's
# own diagnostic points to, globally, so it reaches every plugin subproject
# (permission_handler_windows is a pub.dev dep we cannot edit). Remove once the
# affected plugins drop <experimental/coroutine>.
add_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)

# Compilation settings that should be applied to most targets.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")

# Flutter library and tool build rules.
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build
add_subdirectory("runner")

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# === fushidicts native dictionary engine ===
set(FUSHIDICTS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushidicts")
add_subdirectory("${FUSHIDICTS_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/fushidicts")

# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} fushi_update_launcher
  RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Install fushidicts DLL next to the executable
install(TARGETS fushidicts_ffi RUNTIME DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# === 内置 libtorrent 引擎（Debug 可选，Profile/Release 必需）===
# fushi_torrent 依赖 libtorrent+boost+openssl（vcpkg 首次源码编译约 40min），
# 不强制只做 UI 的开发机构建它。故采用本机预编译：由
# native/fushi_torrent/build_windows_dll.ps1 事先产出 4 个 DLL 到
# prebuilt/windows-x64/。Debug 缺失时仍可构建（运行时明确报告后端不可用）；
# Profile/Release 缺失时由下方 install 守卫失败，禁止生成残缺安装包。
set(FUSHI_TORRENT_PREBUILT_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushi_torrent/prebuilt/windows-x64")
set(FUSHI_TORRENT_DLLS
  "fushi_torrent_ffi.dll"
  "torrent-rasterbar.dll"
  "libssl-3-x64.dll"
  "libcrypto-3-x64.dll")
foreach(_dll ${FUSHI_TORRENT_DLLS})
  set(_dll_path "${FUSHI_TORRENT_PREBUILT_DIR}/${_dll}")
  if(EXISTS "${_dll_path}")
    install(FILES "${_dll_path}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
      COMPONENT Runtime)
  endif()
endforeach()

# Debug builds may intentionally omit the expensive libtorrent prebuild so UI
# work stays lightweight. A Profile/Release bundle, however, must never be
# produced while advertising an embedded backend that cannot open at runtime.
# Check at install time because Flutter's Visual Studio generator is
# multi-config and CMAKE_BUILD_TYPE is empty during configure.
install(CODE "
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES \"^(Profile|Release)$\")
    foreach(_dll IN ITEMS
        fushi_torrent_ffi.dll
        torrent-rasterbar.dll
        libssl-3-x64.dll
        libcrypto-3-x64.dll)
      if(NOT EXISTS \"${FUSHI_TORRENT_PREBUILT_DIR}/\${_dll}\")
        message(FATAL_ERROR
          \"Missing required Windows download runtime: \${_dll}. \"
          \"Run native/fushi_torrent/build_windows_dll.ps1 before building a Profile/Release bundle.\")
      endif()
    endforeach()
  endif()
" COMPONENT Runtime)

# === galgame hook helper 随包普通文件（可选，本地/CI 事先构建）===
# helper（injector exe + hook DLL）**绝不链接进 fushi.exe**。BUG-1449 起，两个架构由
# install_into_bundle.ps1 在构建期校验 zip 后解包到 exe 同级 voice_hook/<arch>/；安装包
# 不再携带 galgame_helper/ zip，也不再依赖运行期把第二份副本同步到 plain files。
#
# 本地 Debug 仍允许没跑 build_distribution.ps1：这对只改 UI 的开发机构建是必要的。
# 但增量输出目录可能残留上一次构建的 voice_hook/。若这次 dist 不完整，或 dist 的源码
# 指纹不属于当前 checkout，安装脚本必须主动删掉残留而不是把旧 DLL 伪装成新构建
#（BUG-1868）；功能明确不可用胜过静默注入旧件。
# CI/Release 随后仍会无 AllowMissingDistribution 调用同一脚本，分发物缺失或损坏时失败。
# 要在本地拿到 helper：先在 native/galgame_hook 下跑 tools/build_distribution.ps1。
set(FUSHI_GALGAME_HELPER_DIST_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/galgame_hook/dist")
set(FUSHI_GALGAME_HELPER_INSTALL_SCRIPT
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/galgame_hook/tools/install_into_bundle.ps1")
install(CODE "
  execute_process(
    COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass
      -File \"${FUSHI_GALGAME_HELPER_INSTALL_SCRIPT}\"
      -BundleDirectory \"${CMAKE_INSTALL_PREFIX}\"
      -DistDirectory \"${FUSHI_GALGAME_HELPER_DIST_DIR}\"
      -AllowMissingDistribution
    RESULT_VARIABLE _galgame_helper_result
    OUTPUT_VARIABLE _galgame_helper_stdout
    ERROR_VARIABLE _galgame_helper_stderr)
  if(NOT _galgame_helper_result EQUAL 0)
    message(FATAL_ERROR
      \"install_into_bundle.ps1 failed (\${_galgame_helper_result}):\\n\"
      \"\${_galgame_helper_stdout}\\n\${_galgame_helper_stderr}\")
  endif()
  if(NOT \"\${_galgame_helper_stdout}\" STREQUAL \"\")
    message(STATUS \"\${_galgame_helper_stdout}\")
  endif()
" COMPONENT Runtime)

# === Magpie 随包精简归档（可选，本地/CI 事先构建）===
# 与上面的 helper 规则同源同理由（BUG-1246）：Magpie 删掉下载链路之后，`magpie_bundle/`
# 只由 CI 在 `flutter build windows` 之后的一个独立 YAML 步骤拷贝，于是 `flutter run` /
# `flutter build windows --debug` 出来的 exe 旁边永远没有这个目录，`_installBundledMagpie`
# 在 `if (!hasZip && !hasSidecar) return false;` 当场返回 false —— 开发构建里窗口超分
# **恒为 bundleMissing**，等于开发模式下这个功能完全用不了、也没法验证。
#
# 产物来自 repo 根 `dist/`（tools/build_magpie_slim.ps1 的默认 OutputDir），与 release
# 同源、同文件名、同目标目录；CI 那步照旧保留，它跑在本规则之后，是幂等覆盖。
# OPTIONAL 同样必需：判定发生在 install 时而非 configure 时，没跑过组包脚本的机器照常
# `flutter build windows` 成功，只是超分报「安装包不完整」——与今天的行为一致。
# 要在本地拿到它：仓库根跑 `pwsh -File tools/build_magpie_slim.ps1`。
set(FUSHI_MAGPIE_BUNDLE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../dist")
set(FUSHI_MAGPIE_BUNDLE_FILES
  "Magpie-hibiki-slim-x64.zip"
  "Magpie-hibiki-slim-x64.zip.sha256")
foreach(_magpie_file ${FUSHI_MAGPIE_BUNDLE_FILES})
  install(FILES "${FUSHI_MAGPIE_BUNDLE_DIR}/${_magpie_file}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}/magpie_bundle"
    COMPONENT Runtime OPTIONAL)
endforeach()

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
