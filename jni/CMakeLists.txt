cmake_minimum_required(VERSION 3.22.1)
project(hide_devmode CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ------------------------------------------------------------------------------
# Module library
# Tối ưu kích thước & ẩn symbol. Module Zygisk được dlopen() vào tiến trình
# app, càng nhỏ + ít symbol public càng khó bị app bảo mật scan ra.
# ------------------------------------------------------------------------------
add_library(zygisk_hide_devmode SHARED
    src/main.cpp
    src/config.cpp
    src/hook_properties.cpp
    src/hook_settings.cpp
)

target_include_directories(zygisk_hide_devmode PRIVATE
    include
    src
)

target_link_libraries(zygisk_hide_devmode PRIVATE
    log
)

target_compile_options(zygisk_hide_devmode PRIVATE
    -Wall
    -Wextra
    -Werror
    -Wno-unused-parameter
    -fvisibility=hidden
    -fvisibility-inlines-hidden
    -ffunction-sections
    -fdata-sections
    -fno-rtti
    -fno-exceptions
)

target_link_options(zygisk_hide_devmode PRIVATE
    -Wl,--gc-sections
    -Wl,--exclude-libs,ALL
    -Wl,--hash-style=both
    -Wl,-z,max-page-size=16384      # tương thích Android 15+ pagesize 16KB
)

if (CMAKE_BUILD_TYPE STREQUAL "Release")
    target_compile_options(zygisk_hide_devmode PRIVATE -O2)
endif()

# Tên file output bắt buộc tuân theo convention zygisk:
#   /data/adb/modules/<id>/zygisk/<arch>.so
set_target_properties(zygisk_hide_devmode PROPERTIES
    OUTPUT_NAME zygisk_hide_devmode
    PREFIX "lib"
)

# Strip symbols ở release để giảm kích thước & ẩn dấu vết.
if (CMAKE_BUILD_TYPE STREQUAL "Release")
    add_custom_command(TARGET zygisk_hide_devmode POST_BUILD
        COMMAND ${CMAKE_STRIP} --strip-all $<TARGET_FILE:zygisk_hide_devmode>
        COMMENT "Stripping release binary")
endif()
