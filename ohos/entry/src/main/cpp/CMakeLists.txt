cmake_minimum_required(VERSION 3.16)
project(azahar_ohos)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(AZAHAR_OHOS_STANDALONE ON)
else()
    set(AZAHAR_OHOS_STANDALONE OFF)
endif()

add_definitions(
    -DOHOS=1
    -D__OHOS__=1
    -DMOBILE_DEVICE=1
)

add_library(azahar_ohos SHARED
    core/azahar_core_bridge.cpp
    core/ohos_jit_capability.cpp
    graphics/ohos_graphics_info.cpp
    graphics/ohos_xcomponent_bridge.cpp
    napi_init.cpp
)

target_compile_options(azahar_ohos PRIVATE
    -Wall
    -Wextra
    -Wno-unused-parameter
    -fvisibility=default
)

target_link_options(azahar_ohos PRIVATE
    -Wl,--undefined=RegisterAzaharModule
    -Wl,--undefined=NativeXComponentInit
    # Thin LTO 的代码生成发生在链接期且默认无缓存：每个 cpp 改动都会触发全量
    # 后端编译（数分钟）。开启 lld thinlto 缓存后只重编译受影响模块。
    -Wl,--thinlto-cache-dir=${CMAKE_BINARY_DIR}/thinlto-cache
)

if(TARGET citra_core)
    target_sources(azahar_ohos PRIVATE
        camera/ohos_camera.cpp
        camera/ohos_still_image_camera.cpp
        core/azahar_core_runtime.cpp
        graphics/ohos_emu_window.cpp
        input/ohos_gamepad.cpp
        input/ohos_input.cpp
    )
    target_compile_definitions(azahar_ohos PRIVATE AZAHAR_OHOS_CORE_AVAILABLE=1)
    if(ENABLE_OPENGL)
        target_compile_definitions(azahar_ohos PRIVATE ENABLE_OPENGL)
    endif()
    if(ENABLE_VULKAN)
        target_compile_definitions(azahar_ohos PRIVATE ENABLE_VULKAN)
        target_link_libraries(azahar_ohos PRIVATE vulkan-headers)
    endif()
    if(ENABLE_SOFTWARE_RENDERER)
        target_compile_definitions(azahar_ohos PRIVATE ENABLE_SOFTWARE_RENDERER)
    endif()
    target_include_directories(azahar_ohos PRIVATE
        ${CMAKE_SOURCE_DIR}/src
        ${CMAKE_SOURCE_DIR}/src/android/app/src/main
        ${CMAKE_CURRENT_SOURCE_DIR}
    )
    target_link_libraries(azahar_ohos PRIVATE
        audio_core
        citra_common
        citra_core
        glad
        input_common
        json-headers
        lodepng
        network
        video_core
        yuv
        libability_access_control.so
        libohcamera.so
        libohgame_controller.z.so
        libohsensor.so
        libimage_receiver.so
        libimage_source.so
        libnative_buffer.so
        libnative_image.so
        libohimage.so
        libpixelmap.so
    )
    # Compile the native Catch2 suite into the shared library so it can run
    # on retail devices where the shell cannot exec standalone binaries.
    # Triggered via `aa start --ps runNativeTests true`; results go to hilog.
    if(ENABLE_OHOS_TESTS)
        target_sources(azahar_ohos PRIVATE
            tests/ohos_native_tests.cpp
            ${CMAKE_SOURCE_DIR}/src/tests/core/arm/arm_test_common.cpp
            ${CMAKE_SOURCE_DIR}/src/tests/core/arm/asm_interpreter.cpp
            ${CMAKE_SOURCE_DIR}/src/tests/core/arm/ir_interpreter.cpp
        )
        target_compile_definitions(azahar_ohos PRIVATE AZAHAR_OHOS_TESTS=1)
        target_link_libraries(azahar_ohos PRIVATE
            Catch2::Catch2
            nihstro-headers
            Threads::Threads
        )
    endif()
else()
    target_compile_definitions(azahar_ohos PRIVATE AZAHAR_OHOS_CORE_AVAILABLE=0)
endif()

# Device Security Kit 仅存在于 HMS sysroot，不在链接默认搜索路径，需 find_library
find_library(OHOS_DSM_LIB libdevice_security_mode.z.so)
if(NOT OHOS_DSM_LIB)
    message(FATAL_ERROR "Device Security Mode library not found: libdevice_security_mode.z.so")
endif()

target_link_libraries(azahar_ohos PUBLIC
    libace_napi.z.so
    libace_ndk.z.so
    ${OHOS_DSM_LIB}
    libEGL.so
    libGLESv3.so
    libhilog_ndk.z.so
    libnative_window.so
)

# ============================================================================
# HarmonyOS release 性能优化（对齐 ../nds、../ppsspp 端口的做法）
# ============================================================================
# -O3 + 向量化/循环展开。OHOS 工具链默认只给 -O2（ohos.toolchain.cmake 的
# OHOS_RELEASE_COMPILER_FLAGS），这里显式覆盖。
# 禁止 -ffast-math 及其子选项（-ffinite-math-only、-fno-signed-zeros 等）：
# 会破坏模拟 GPU 的浮点精度（PICA200 纹理坐标、NaN 传播）。
# -fno-math-errno 是安全的——只跳过 errno 写入，不影响数值精度。
if(CMAKE_BUILD_TYPE STREQUAL "Release" OR CMAKE_BUILD_TYPE STREQUAL "RelWithDebInfo")
    set(AZAHAR_OHOS_RELEASE_FLAGS
        -O3
        -funroll-loops
        -fvectorize
        -fslp-vectorize
        -finline-functions
        -fomit-frame-pointer
        -fno-math-errno
    )

    # 模拟器自身库
    set(AZAHAR_OHOS_OPTIMIZED_TARGETS
        azahar_ohos
        audio_core
        citra_common
        citra_core
        input_common
        network
        video_core
        web_service
    )
    # 性能敏感的第三方库：dynarmic(ARM JIT) / teakra(DSP) / sirit(shader IR)
    # / SoundTouch(音频拉伸) / faad2(AAC 解码)
    set(AZAHAR_OHOS_OPTIMIZED_EXTERNALS
        dynarmic
        mcl
        teakra
        sirit
        SoundTouch
        faad2
    )
    foreach(_target IN LISTS AZAHAR_OHOS_OPTIMIZED_TARGETS AZAHAR_OHOS_OPTIMIZED_EXTERNALS)
        if(TARGET ${_target})
            target_compile_options(${_target} PRIVATE ${AZAHAR_OHOS_RELEASE_FLAGS})
        endif()
    endforeach()

    # Thin LTO：src/CMakeLists.txt 的 CMAKE_INTERPROCEDURAL_OPTIMIZATION 是
    # 目录作用域，只覆盖 src/*。azahar_ohos 与上述第三方库在此显式开启，
    # 否则跨库边界的调用无法被链接期内联。只给热路径库开，glslang /
    # SPIRV-Tools / crypto / boost 等非热路径的大库不加入，控制链接耗时。
    # IPO 属性同时给编译和链接步骤补上 -flto=thin。
    if(ENABLE_LTO)
        set_property(TARGET azahar_ohos PROPERTY INTERPROCEDURAL_OPTIMIZATION TRUE)

        # 部分第三方库 cmake_minimum_required 过旧（CMP0069=OLD），IPO 属性
        # 会被忽略，改为直接追加 -flto=thin 编译选项，效果相同。
        foreach(_target IN LISTS AZAHAR_OHOS_OPTIMIZED_EXTERNALS)
            if(TARGET ${_target})
                target_compile_options(${_target} PRIVATE -flto=thin)
            endif()
        endforeach()
    endif()
endif()
