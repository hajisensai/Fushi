# The Flutter tooling requires that developers have CMake 3.10 or later installed. You should not increase this version,
# as doing so will cause the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "flutter_onnxruntime")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must not be changed.
set(PLUGIN_NAME "flutter_onnxruntime_plugin")

# === ONNX Runtime configuration (Fushi fork) ===
# Bundled: the latest CPU core (Microsoft.ML.OnnxRuntime). It is the revision the
# official CUDA plugin EP is built against, so CUDA (plugin-ep-cuda + cuBLAS /
# cuDNN, downloaded by the app and registered at runtime, src/cuda_provider.cc)
# runs core and plugin from the same ORT revision - the release notes warn that
# mismatched contributed-operator schemas can execute incorrectly undetected.
#
# NOT bundled: DirectML. It only ships in Microsoft.ML.OnnxRuntime.DirectML,
# whose last release is 1.24.4; the app downloads that core (+ DirectML.dll) on
# demand and maps it before ORT is first bound (src/ort_runtime_loader.cc). The
# plugin therefore links onnxruntime.dll with /DELAYLOAD and pins the ORT API
# version it requests (kOrtApiVersionUsed) so either core can serve it. The
# DirectML package is still fetched at build time, but only for
# dml_provider_factory.h (DirectML.h comes from the Windows SDK).
set(ONNXRUNTIME_VERSION "1.31.0")
set(ONNXRUNTIME_NUPKG_SHA256 "7E35FDB4F5ADB62F01E60798E2E5ED05108F5FBBE1CCA03FBCC37903CF7C5E3B")
set(ONNXRUNTIME_DML_VERSION "1.24.4")
set(ONNXRUNTIME_DML_NUPKG_SHA256 "57E9F11B73437BEF7A309496135D4C1F96B1A8E9DDBA60013FA27BFC1D788681")

if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64" OR CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64|aarch64)$")
  set(ONNXRUNTIME_RID "win-arm64")
else()
  set(ONNXRUNTIME_RID "win-x64")
endif()

set(ONNXRUNTIME_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/onnxruntime-${ONNXRUNTIME_VERSION}")
set(ONNXRUNTIME_EXTRACT_DIR "${ONNXRUNTIME_DOWNLOAD_DIR}/onnxruntime")
set(ONNXRUNTIME_NUPKG "${ONNXRUNTIME_DOWNLOAD_DIR}/onnxruntime.nupkg")
set(ONNXRUNTIME_DML_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/onnxruntime-directml-${ONNXRUNTIME_DML_VERSION}")
set(ONNXRUNTIME_DML_EXTRACT_DIR "${ONNXRUNTIME_DML_DOWNLOAD_DIR}/onnxruntime")
set(ONNXRUNTIME_DML_NUPKG "${ONNXRUNTIME_DML_DOWNLOAD_DIR}/onnxruntime-directml.nupkg")

function(fushi_fetch_nupkg URL NUPKG SHA256 EXTRACT_DIR SENTINEL)
  if(EXISTS "${SENTINEL}")
    return()
  endif()
  file(MAKE_DIRECTORY "${EXTRACT_DIR}")
  file(
    DOWNLOAD "${URL}" "${NUPKG}"
    EXPECTED_HASH "SHA256=${SHA256}"
    TLS_VERIFY ON
    SHOW_PROGRESS)
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E tar xf "${NUPKG}"
    WORKING_DIRECTORY "${EXTRACT_DIR}"
    RESULT_VARIABLE EXTRACT_RESULT)
  if(NOT EXTRACT_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to extract ${NUPKG}: ${EXTRACT_RESULT}")
  endif()
endfunction()

fushi_fetch_nupkg(
  "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/${ONNXRUNTIME_VERSION}/microsoft.ml.onnxruntime.${ONNXRUNTIME_VERSION}.nupkg"
  "${ONNXRUNTIME_NUPKG}" "${ONNXRUNTIME_NUPKG_SHA256}" "${ONNXRUNTIME_EXTRACT_DIR}"
  "${ONNXRUNTIME_EXTRACT_DIR}/runtimes/${ONNXRUNTIME_RID}/native/onnxruntime.dll")
fushi_fetch_nupkg(
  "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/${ONNXRUNTIME_DML_VERSION}/microsoft.ml.onnxruntime.directml.${ONNXRUNTIME_DML_VERSION}.nupkg"
  "${ONNXRUNTIME_DML_NUPKG}" "${ONNXRUNTIME_DML_NUPKG_SHA256}" "${ONNXRUNTIME_DML_EXTRACT_DIR}"
  "${ONNXRUNTIME_DML_EXTRACT_DIR}/build/native/include/dml_provider_factory.h")

set(ONNXRUNTIME_INCLUDE_DIRS "${ONNXRUNTIME_EXTRACT_DIR}/build/native/include")
set(ONNXRUNTIME_DML_HEADER_DIR "${CMAKE_CURRENT_BINARY_DIR}/onnxruntime-dml-header")
file(MAKE_DIRECTORY "${ONNXRUNTIME_DML_HEADER_DIR}")
# Only the DirectML factory header: the rest of the include tree must be the
# bundled core's.
file(COPY "${ONNXRUNTIME_DML_EXTRACT_DIR}/build/native/include/dml_provider_factory.h"
     DESTINATION "${ONNXRUNTIME_DML_HEADER_DIR}")
set(ONNXRUNTIME_NATIVE_DIR "${ONNXRUNTIME_EXTRACT_DIR}/runtimes/${ONNXRUNTIME_RID}/native")
set(ONNXRUNTIME_LIBRARY "${ONNXRUNTIME_NATIVE_DIR}/onnxruntime.lib")
set(ONNXRUNTIME_DLL "${ONNXRUNTIME_NATIVE_DIR}/onnxruntime.dll")
set(ONNXRUNTIME_PROVIDERS_SHARED_DLL "${ONNXRUNTIME_NATIVE_DIR}/onnxruntime_providers_shared.dll")

foreach(REQUIRED_FILE IN ITEMS "${ONNXRUNTIME_LIBRARY}" "${ONNXRUNTIME_DLL}" "${ONNXRUNTIME_PROVIDERS_SHARED_DLL}")
  if(NOT EXISTS "${REQUIRED_FILE}")
    message(FATAL_ERROR "Required ONNX Runtime artifact is missing: ${REQUIRED_FILE}")
  endif()
endforeach()

set(ONNXRUNTIME_LIBRARIES "${ONNXRUNTIME_LIBRARY}")
set(flutter_onnxruntime_bundled_libraries "${ONNXRUNTIME_DLL}" "${ONNXRUNTIME_PROVIDERS_SHARED_DLL}")

# Define Windows-specific preprocessor macros
add_definitions(-DWIN32_LEAN_AND_MEAN -DNOMINMAX -DUNICODE -D_UNICODE)
# Fushi fork: the C++ API is bound explicitly once the core is chosen
# (OrtRuntimeLoader::Ensure), never by a static initializer at DLL load.
add_definitions(-DORT_API_MANUAL_INIT)

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES "src/async_dispatch.cc" "src/cuda_provider.cc" "src/dml_provider.cc" "src/dxgi_memory.cc"
  "src/ort_runtime_loader.cc"
  "src/session_manager.cc" "src/value_conversion.cc" "src/tensor_manager.cc"
     "src/windows_utils.cc")

# Define the plugin library target. Its name must not be changed (see comment on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED "flutter_onnxruntime_plugin.cpp" "flutter_onnxruntime_plugin.h" ${PLUGIN_SOURCES})

# Apply a standard set of build settings that are configured in the application-level CMakeLists.txt. This can be
# removed for plugins that want full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts between plugins. This should not be
# removed; any symbols that should be exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL FLUTTER_ONNXRUNTIME_HAS_DIRECTML=1)

# Add WINDOWS_EXPORT_ALL_SYMBOLS to ensure the generation of the import library (.lib file)
set_target_properties(${PLUGIN_NAME} PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)

# Enable C++17 features
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)

# Source include directories and library dependencies. Add any plugin-specific dependencies here.
target_include_directories(
  ${PLUGIN_NAME} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include" "${CMAKE_CURRENT_SOURCE_DIR}" "${FLUTTER_EPHEMERAL_DIR}"
                         "${CMAKE_CURRENT_SOURCE_DIR}/windows/include" "${ONNXRUNTIME_INCLUDE_DIRS}")

# Install debugging message
message(STATUS "Include directories: ${CMAKE_CURRENT_SOURCE_DIR}/include")
message(STATUS "Binary directory: ${CMAKE_CURRENT_BINARY_DIR}/include")
message(STATUS "This file: ${CMAKE_CURRENT_LIST_FILE}")

# Install public headers for the plugin
install(FILES "include/flutter_onnxruntime/flutter_onnxruntime_plugin.h" "include/flutter_onnxruntime/export.h"
        DESTINATION "${CMAKE_BINARY_DIR}/include/flutter_onnxruntime")

# Also create symlinks in the build directory to ensure includes work during build
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/include/flutter_onnxruntime")

# Copy headers with error handling
file(
  COPY "${CMAKE_CURRENT_SOURCE_DIR}/include/flutter_onnxruntime/flutter_onnxruntime_plugin.h"
  DESTINATION "${CMAKE_BINARY_DIR}/include/flutter_onnxruntime/"
  FOLLOW_SYMLINK_CHAIN)

file(
  COPY "${CMAKE_CURRENT_SOURCE_DIR}/include/flutter_onnxruntime/export.h"
  DESTINATION "${CMAKE_BINARY_DIR}/include/flutter_onnxruntime/"
  FOLLOW_SYMLINK_CHAIN)

# Add include directories for the plugin
target_include_directories(${PLUGIN_NAME} PUBLIC $<BUILD_INTERFACE:${CMAKE_BINARY_DIR}/include>
                                                 $<INSTALL_INTERFACE:include>)

# Add ONNX Runtime include directories
target_include_directories(${PLUGIN_NAME} PRIVATE ${ONNXRUNTIME_INCLUDE_DIRS} "${ONNXRUNTIME_DML_HEADER_DIR}")

# Link against Flutter and other libraries
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Link against ONNX Runtime, delay-loaded (see the configuration block above).
target_link_libraries(${PLUGIN_NAME} PRIVATE ${ONNXRUNTIME_LIBRARIES} delayimp)
target_link_options(${PLUGIN_NAME} PRIVATE "/DELAYLOAD:onnxruntime.dll")

# Link against Windows Shell API library for PathRemoveFileSpecW
target_link_libraries(${PLUGIN_NAME} PRIVATE Shlwapi dxgi)

# Copy the bundled ONNX Runtime next to the plugin for local runs. Flutter
# also consumes flutter_onnxruntime_bundled_libraries when assembling the app.
foreach(BUNDLED_LIBRARY IN LISTS flutter_onnxruntime_bundled_libraries)
  add_custom_command(
    TARGET ${PLUGIN_NAME}
    POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${BUNDLED_LIBRARY}" $<TARGET_FILE_DIR:${PLUGIN_NAME}>
    COMMENT "Copying ${BUNDLED_LIBRARY} to plugin build directory")
endforeach()

# List of absolute paths to libraries that should be bundled with the plugin. This list could contain prebuilt
# libraries, or libraries created by an external build triggered from this build file.
set(flutter_onnxruntime_bundled_libraries
    "${flutter_onnxruntime_bundled_libraries}"
    PARENT_SCOPE)
