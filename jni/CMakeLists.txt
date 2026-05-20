cmake_minimum_required(VERSION 3.22.1)
project(hide_devmode CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ------------------------------------------------------------------------------
# Compile flags - tối ưu kích thước & ẩn symbol.
# Module Zygisk được dlopen() vào tiến trình app, càng nhỏ + ít symbol public
# càng khó bị các app bảo mật scan ra.
# ------------------------------------------------------------------------------
set(COMMON_FLAGS
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
    -fno-stack-protector
)

if (CMAKE_BUILD_TYPE STREQUAL "Release")
    list(APPEND COMMON_FLAGS -O2 -flto)
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -flto")
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -flto")
endif()

add_compile_options(${COMMON_FLAGS})
add_link_options(
    -Wl,--gc-sections
    -Wl,--exclude-libs,ALL
    -Wl,--hash-style=both
    -Wl,-z,max-page-size=16384      # tương thích Android 15+ pagesize 16KB
)

# ------------------------------------------------------------------------------
# Dobby - native inline hook engine.
# User cần đặt source Dobby vào external/Dobby (xem README.md).
# Nếu không tìm thấy, build sẽ fail với thông báo rõ ràng.
# ------------------------------------------------------------------------------
set(DOBBY_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../external/Dobby)
if (NOT EXISTS ${DOBBY_DIR}/CMakeLists.txt)
    message(FATAL_ERROR
        "Không tìm thấy Dobby tại ${DOBBY_DIR}.\n"
        "Hãy chạy: git clone https://github.com/asLody/Dobby external/Dobby --depth=1")
endif()

set(DOBBY_GENERATE_SHARED OFF CACHE BOOL "" FORCE)
set(DOBBY_BUILD_EXAMPLE   OFF CACHE BOOL "" FORCE)
set(DOBBY_BUILD_TEST      OFF CACHE BOOL "" FORCE)
set(DOBBY_DEBUG           OFF CACHE BOOL "" FORCE)
add_subdirectory(${DOBBY_DIR} ${CMAKE_BINARY_DIR}/dobby EXCLUDE_FROM_ALL)

# ------------------------------------------------------------------------------
# Module library
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
    ${DOBBY_DIR}/include
)

target_link_libraries(zygisk_hide_devmode PRIVATE
    dobby_static
    log
)

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
