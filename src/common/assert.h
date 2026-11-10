// Copyright 2013 Dolphin Emulator Project / 2014 Citra Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#pragma once

#include <cstdio>
#include <cstdlib>
#include "common/common_funcs.h"
#include "common/logging/backend.h"
#include "common/logging/log.h"

#if defined(__OHOS__)
#include <hilog/log.h>
// Citra logs go to stderr which hilog never sees on OHOS; drop a marker
// file so abort sites are identifiable on-device.
inline void OhosAssertMarker() {
    OH_LOG_Print(LOG_APP, LOG_FATAL, 0x3203, "AzaharAssert", "ASSERTION FAILED");
    const char* paths[] = {
        "/data/storage/el2/base/files/asm_assert.txt",
        "/data/app/el2/100/base/app.superedu.3ds/files/asm_assert.txt",
        "/data/local/tmp/asm_assert.txt",
    };
    for (const char* p : paths) {
        if (FILE* f = std::fopen(p, "a")) {
            std::fprintf(f, "assert_noinline_call hit\n");
            std::fclose(f);
            break;
        }
    }
}
#else
inline void OhosAssertMarker() {}
#endif

// For asserts we'd like to keep all the junk executed when an assert happens away from the
// important code in the function. One way of doing this is to put all the relevant code inside a
// lambda and force the compiler to not inline it.

#define ASSERT(_a_)                                                                                \
    do                                                                                             \
        if (!(_a_)) [[unlikely]] {                                                                 \
            []() CITRA_NO_INLINE CITRA_NO_RETURN {                                                 \
                LOG_CRITICAL(Debug, "Assertion Failed!");                                          \
                Common::Log::Stop();                                                               \
                OhosAssertMarker(); Crash();                                                                           \
                exit(1);                                                                           \
            }();                                                                                   \
        }                                                                                          \
    while (0)

#define ASSERT_MSG(_a_, ...)                                                                       \
    do                                                                                             \
        if (!(_a_)) [[unlikely]] {                                                                 \
            [&]() CITRA_NO_INLINE CITRA_NO_RETURN {                                                \
                LOG_CRITICAL(Debug, "Assertion Failed!\n" __VA_ARGS__);                            \
                Common::Log::Stop();                                                               \
                OhosAssertMarker(); Crash();                                                                           \
                exit(1);                                                                           \
            }();                                                                                   \
        }                                                                                          \
    while (0)

#define UNREACHABLE()                                                                              \
    ([]() CITRA_NO_INLINE CITRA_NO_RETURN {                                                        \
        LOG_CRITICAL(Debug, "Unreachable code!");                                                  \
        Common::Log::Stop();                                                                       \
        OhosAssertMarker(); Crash();                                                                                   \
        exit(1);                                                                                   \
    }())

#define UNREACHABLE_MSG(...)                                                                       \
    ([&]() CITRA_NO_INLINE CITRA_NO_RETURN {                                                       \
        LOG_CRITICAL(Debug, "Unreachable code!\n" __VA_ARGS__);                                    \
        Common::Log::Stop();                                                                       \
        OhosAssertMarker(); Crash();                                                                                   \
        exit(1);                                                                                   \
    }())

#ifdef _DEBUG
#define DEBUG_ASSERT(_a_) ASSERT(_a_)
#define DEBUG_ASSERT_MSG(_a_, ...) ASSERT_MSG(_a_, __VA_ARGS__)
#else // not debug
#define DEBUG_ASSERT(_a_)
#define DEBUG_ASSERT_MSG(_a_, _desc_, ...)
#endif

#define UNIMPLEMENTED() LOG_CRITICAL(Debug, "Unimplemented code!")
#define UNIMPLEMENTED_MSG(_a_, ...) LOG_CRITICAL(Debug, _a_, __VA_ARGS__)
