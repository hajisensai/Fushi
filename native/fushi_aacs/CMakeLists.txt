cmake_minimum_required(VERSION 3.14)

project(fushi_aacs LANGUAGES C)

option(FUSHI_AACS_BUILD_TESTS "Build the fushi_aacs self-test executable" OFF)

add_library(fushi_aacs SHARED
  src/fushi_aacs.c
  src/fushi_aacs_crypto.c
)
set_target_properties(fushi_aacs PROPERTIES
  C_STANDARD 99
  C_STANDARD_REQUIRED ON
  C_VISIBILITY_PRESET hidden
)
if(MSVC)
  target_compile_definitions(fushi_aacs PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# libbluray locates the module by the name libaacs uses on each platform
# (libbluray-1.5.0 src/libbluray/disc/aacs.c + src/file/dl_*.c):
#   Windows  LoadLibraryExW("libaacs.dll", APPLICATION_DIR | SYSTEM32)
#   Android  dlopen("libaacs.so.0"): APKs cannot carry that file name, so the
#            library keeps an APK-safe file name and declares the soname the
#            app preloads; bionic resolves later bare-name opens by soname.
#   macOS    dlopen("@rpath/libaacs.dylib") among its search paths.
if(WIN32)
  set_target_properties(fushi_aacs PROPERTIES PREFIX "" OUTPUT_NAME "libaacs")
elseif(ANDROID)
  set_target_properties(fushi_aacs PROPERTIES OUTPUT_NAME "fushi_aacs" NO_SONAME ON)
  target_link_options(fushi_aacs PRIVATE "-Wl,-soname,libaacs.so.0"
    "-Wl,-z,max-page-size=16384")
elseif(APPLE)
  set_target_properties(fushi_aacs PROPERTIES
    OUTPUT_NAME "aacs"
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_NAME_DIR ON)
else()
  set_target_properties(fushi_aacs PROPERTIES OUTPUT_NAME "fushi_aacs"
    NO_SONAME ON)
  target_link_options(fushi_aacs PRIVATE "-Wl,-soname,libaacs.so.0")
  target_link_libraries(fushi_aacs PRIVATE pthread)
endif()

if(FUSHI_AACS_BUILD_TESTS)
  enable_testing()
  add_executable(fushi_aacs_test test/fushi_aacs_test.c)
  target_link_libraries(fushi_aacs_test PRIVATE fushi_aacs)
  target_include_directories(fushi_aacs_test PRIVATE src)
  # The test also exercises the crypto primitives directly.
  target_sources(fushi_aacs_test PRIVATE src/fushi_aacs_crypto.c)
  if(MSVC)
    target_compile_definitions(fushi_aacs_test PRIVATE _CRT_SECURE_NO_WARNINGS)
  endif()
  add_test(NAME fushi_aacs_test COMMAND fushi_aacs_test)
  if(WIN32)
    set_tests_properties(fushi_aacs_test PROPERTIES
      ENVIRONMENT_MODIFICATION "PATH=path_list_prepend:$<TARGET_FILE_DIR:fushi_aacs>")
  endif()
endif()
