# fushi_update_launcher：应用内更新的交接进程（源码在 runner/update_launcher.cpp）。
#
# BUG-5529：launcher 必须**静态链接 CRT（/MT）**，不依赖任何随包 DLL。
# 它是安装器唯一刻意不杀、要活到安装结束的进程（BUG-1708 / BUG-1786），可安装目录里
# 恰好随包带着 msvcp140.dll / vcruntime140*.dll（TODO-1242：给没装 VC++ 运行库的机器）。
# /MD 编出来的 launcher 在这类机器上会按 DLL 搜索顺序（System32 没有 → 当前目录，
# 继承自 fushi.exe，通常就是安装目录）把 {app}\msvcp140.dll 映射进去并一直持有，
# 复制阶段 DeleteFile code 5 → 整包回滚，更新永远装不上。静态 CRT 让 launcher
# 只依赖 KERNEL32 / SHELL32 / bcrypt 等系统 DLL，无论从副本还是安装目录启动都不碰 {app}。
#
# 单独成目录是因为 CMake 3.14（本项目下限，CMP0091 为 OLD）只能在**目录作用域**里改
# CMAKE_CXX_FLAGS_<CONFIG> 的运行库开关；放在 runner/ 里会把 fushi.exe 一起改成 /MT。
# 守卫：fushi/test/build/update_launcher_static_crt_guard_test.dart。
foreach(flag_var
    CMAKE_C_FLAGS CMAKE_C_FLAGS_DEBUG CMAKE_C_FLAGS_RELEASE CMAKE_C_FLAGS_PROFILE
    CMAKE_C_FLAGS_MINSIZEREL CMAKE_C_FLAGS_RELWITHDEBINFO
    CMAKE_CXX_FLAGS CMAKE_CXX_FLAGS_DEBUG CMAKE_CXX_FLAGS_RELEASE CMAKE_CXX_FLAGS_PROFILE
    CMAKE_CXX_FLAGS_MINSIZEREL CMAKE_CXX_FLAGS_RELWITHDEBINFO)
  if(DEFINED ${flag_var})
    string(REGEX REPLACE "/MD" "/MT" ${flag_var} "${${flag_var}}")
  endif()
endforeach()

add_executable(fushi_update_launcher WIN32
  "${CMAKE_CURRENT_SOURCE_DIR}/../runner/update_launcher.cpp"
)
apply_standard_settings(fushi_update_launcher)
target_compile_definitions(fushi_update_launcher PRIVATE "NOMINMAX")
target_link_libraries(fushi_update_launcher PRIVATE shell32 bcrypt)
