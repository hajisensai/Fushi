# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "fushi")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "app.fushi.reader")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# === fushidicts native dictionary engine ===
# Mirror windows/CMakeLists.txt: the Linux runner did not build/bundle the FFI
# dictionary engine, so libfushidicts_ffi.so was absent and dictionary lookups
# crashed at runtime (DynamicLibrary.open failure). Build it from the shared
# native/ tree and install it next to the other bundled libs (rpath $ORIGIN/lib).
set(FUSHIDICTS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushidicts")
add_subdirectory("${FUSHIDICTS_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/fushidicts")


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Install the fushidicts shared library into the bundle lib dir.
install(TARGETS fushidicts_ffi LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# 互联 P2P 隧道（iroh，copy-if-present）：native/fushi_p2p/build_linux_so.sh 产出
# prebuilt/linux-x64/libfushi_p2p.so 则随包进 bundle/lib/（Dart 侧按 <exe>/lib/ 定位）；
# 缺失时 P2P 能力判不可用，其余互联照常。与 Windows / Android 同一语义。
set(FUSHI_P2P_SO
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushi_p2p/prebuilt/linux-x64/libfushi_p2p.so")
if(EXISTS "${FUSHI_P2P_SO}")
  install(FILES "${FUSHI_P2P_SO}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# SRS 排程内核（fsrs-rs，copy-if-present）：native/fushi_fsrs/build_linux_so.sh 产出
# prebuilt/linux-x64/libfushi_fsrs.so 则随包进 bundle/lib/（Dart 侧按裸名经 $ORIGIN/lib 定位）；
# 缺失时 SRS 原生内核判不可用，构建照常。与 fushi_p2p 同一语义。
set(FUSHI_FSRS_SO
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushi_fsrs/prebuilt/linux-x64/libfushi_fsrs.so")
if(EXISTS "${FUSHI_FSRS_SO}")
  install(FILES "${FUSHI_FSRS_SO}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
# 网页内容核心（fushi_web_core：广告拦截 + 漫画章末广告页识别，Rust）：
# native/fushi_web_core/build_linux_so.sh 产出 prebuilt/linux-x64/libfushi_web_core.so，随包进
# bundle/lib/（Dart 侧按裸名经 $ORIGIN/lib 定位）。**硬依赖**（Dart 侧没有降级分支）：
# Profile/Release bundle 缺它构建失败，Debug 只告警。Linux 网络层不拦广告是插件能力问题，
# 与此无关——cosmetic 隐藏与漫画广告页识别照样要这个库。
set(FUSHI_WEB_CORE_SO
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushi_web_core/prebuilt/linux-x64/libfushi_web_core.so")
if(EXISTS "${FUSHI_WEB_CORE_SO}")
  install(FILES "${FUSHI_WEB_CORE_SO}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
else()
  message(WARNING
    "fushi_web_core: ${FUSHI_WEB_CORE_SO} not found. Run "
    "native/fushi_web_core/build_linux_so.sh; Profile/Release bundles refuse to build without it.")
endif()
install(CODE "
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES \"^(Profile|Release)$\" AND NOT EXISTS \"${FUSHI_WEB_CORE_SO}\")
    message(FATAL_ERROR
      \"Missing required native library libfushi_web_core.so. \"
      \"Run native/fushi_web_core/build_linux_so.sh before building a Profile/Release bundle.\")
  endif()
" COMPONENT Runtime)

# 计算内核（哈希 / 图像 / 文本，**硬依赖**）：native/fushi_compute/build_linux_so.sh 产出
# prebuilt/linux-x64/libfushi_compute.so 随包进 bundle/lib/（Dart 侧按裸名经 $ORIGIN/lib 定位）。
# 与上面几个 copy-if-present 不同：没有 Dart 回退实现，缺库时在配置期直接失败。
set(FUSHI_COMPUTE_SO
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushi_compute/prebuilt/linux-x64/libfushi_compute.so")
if(NOT EXISTS "${FUSHI_COMPUTE_SO}")
  message(FATAL_ERROR
    "fushi_compute is a required native dependency, but ${FUSHI_COMPUTE_SO} is missing. "
    "Build it first: bash native/fushi_compute/build_linux_so.sh (needs Rust/cargo).")
endif()
install(FILES "${FUSHI_COMPUTE_SO}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# RWKV-Instant 排程推理（**硬依赖**，AGPL-3.0-or-later）：native/fushi_rwkv/build_linux_so.sh 产出
# prebuilt/linux-x64/libfushi_rwkv.so 随包进 bundle/lib/（Dart 侧按裸名经 $ORIGIN/lib 定位）。
# 与 fushi_compute 同一语义：没有 Dart 回退实现，缺库时在配置期直接失败。
set(FUSHI_RWKV_SO
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushi_rwkv/prebuilt/linux-x64/libfushi_rwkv.so")
if(NOT EXISTS "${FUSHI_RWKV_SO}")
  message(FATAL_ERROR
    "fushi_rwkv is a required native dependency, but ${FUSHI_RWKV_SO} is missing. "
    "Build it first: bash native/fushi_rwkv/build_linux_so.sh (needs Rust/cargo).")
endif()
install(FILES "${FUSHI_RWKV_SO}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# 内置 libtorrent 引擎（copy-if-present）：native/fushi_torrent/build_linux_so.sh 产出
# prebuilt/linux-x64/libfushi_torrent_ffi.so（vcpkg 静态链 libtorrent/boost/openssl +
# -static-libstdc++，只剩 glibc 动态），与无头服务端随包的是同一份。存在则随包进
# bundle/lib/（Dart 侧 EmbeddedTorrentEngine 按 <exe>/lib/ 定位），缺失时下载后端回退
# 外接 qBittorrent，构建照常——Linux 没有 Windows 那道 Release 强制门：没有 CI / 发布
# 流水线构建 Linux app（所有者 2026-09-30 拍板），本机构建不该因缺 vcpkg 而失败。
set(FUSHI_TORRENT_SO
  "${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushi_torrent/prebuilt/linux-x64/libfushi_torrent_ffi.so")
if(EXISTS "${FUSHI_TORRENT_SO}")
  install(FILES "${FUSHI_TORRENT_SO}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
else()
  message(STATUS
    "fushi_torrent: ${FUSHI_TORRENT_SO} not found; the bundle will not ship the "
    "embedded torrent engine (run native/fushi_torrent/build_linux_so.sh first).")
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
