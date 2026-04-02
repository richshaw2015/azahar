// Copyright 2013 Dolphin Emulator Project / 2014 Citra Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include <string>

#include "common/error.h"
#include "common/logging/log.h"
#include "common/thread.h"
#ifdef __APPLE__
#include <mach/mach.h>
#elif defined(_WIN32)
#include <windows.h>
#include "common/string_util.h"
#else
#if defined(__Bitrig__) || defined(__DragonFly__) || defined(__FreeBSD__) || defined(__OpenBSD__)
#include <pthread_np.h>
#else
#include <pthread.h>
#endif
#include <sched.h>
#endif
#ifndef _WIN32
#include <unistd.h>
#endif

#ifdef OHOS_PLATFORM
#include <dlfcn.h>
#endif

#ifdef __FreeBSD__
#define cpu_set_t cpuset_t
#endif

namespace Common {

#ifdef _WIN32

void SetCurrentThreadPriority(ThreadPriority new_priority) {
    auto handle = GetCurrentThread();
    int windows_priority = 0;
    switch (new_priority) {
    case ThreadPriority::Low:
        windows_priority = THREAD_PRIORITY_BELOW_NORMAL;
        break;
    case ThreadPriority::Normal:
        windows_priority = THREAD_PRIORITY_NORMAL;
        break;
    case ThreadPriority::High:
        windows_priority = THREAD_PRIORITY_ABOVE_NORMAL;
        break;
    case ThreadPriority::VeryHigh:
        windows_priority = THREAD_PRIORITY_HIGHEST;
        break;
    case ThreadPriority::Critical:
        windows_priority = THREAD_PRIORITY_TIME_CRITICAL;
        break;
    default:
        windows_priority = THREAD_PRIORITY_NORMAL;
        break;
    }
    SetThreadPriority(handle, windows_priority);
}

#else

void SetCurrentThreadPriority(ThreadPriority new_priority) {
    pthread_t this_thread = pthread_self();

    const auto scheduling_type = SCHED_OTHER;
    s32 max_prio = sched_get_priority_max(scheduling_type);
    s32 min_prio = sched_get_priority_min(scheduling_type);
    u32 level = std::max(static_cast<u32>(new_priority) + 1, 4U);

    struct sched_param params;
    if (max_prio > min_prio) {
        params.sched_priority = min_prio + ((max_prio - min_prio) * level) / 4;
    } else {
        params.sched_priority = min_prio - ((min_prio - max_prio) * level) / 4;
    }

    pthread_setschedparam(this_thread, scheduling_type, &params);
}

#endif

#ifdef _MSC_VER

// Sets the debugger-visible name of the current thread.
void SetCurrentThreadName(const char* name) {
    SetThreadDescription(GetCurrentThread(), UTF8ToUTF16W(name).data());
}

#else // !MSVC_VER, so must be POSIX threads

// MinGW with the POSIX threading model does not support pthread_setname_np
#if !defined(_WIN32) || defined(_MSC_VER)
void SetCurrentThreadName(const char* name) {
#ifdef __APPLE__
    pthread_setname_np(name);
#elif defined(__Bitrig__) || defined(__DragonFly__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    pthread_set_name_np(pthread_self(), name);
#elif defined(__NetBSD__)
    pthread_setname_np(pthread_self(), "%s", (void*)name);
#elif defined(__linux__)
    // Linux limits thread names to 15 characters and will outright reject any
    // attempt to set a longer name with ERANGE.
    std::string truncated(name, std::min(strlen(name), static_cast<std::size_t>(15)));
    if (int e = pthread_setname_np(pthread_self(), truncated.c_str())) {
        errno = e;
        LOG_ERROR(Common, "Failed to set thread name to '{}': {}", truncated, GetLastErrorMsg());
    }
#else
    pthread_setname_np(pthread_self(), name);
#endif

#ifdef OHOS_PLATFORM
    // ========================================================================
    // HarmonyOS QoS 自动设置 (对齐 NDS ohos_platform.cpp ThreadEntry)
    // ========================================================================
    // 根据鸿蒙官方文档 (qos-guidelines.md):
    // - QOS_USER_INTERACTIVE (等级 5): 用户交互任务，适用于渲染线程
    // - QOS_DEADLINE_REQUEST (等级 4): 越快越好的关键任务，适用于 GPU 工作线程
    // - QOS_USER_INITIATED (等级 3): 用户触发的任务
    //
    // Citra 内部线程 QoS 映射:
    // - VulkanPresent: 呈现线程，直接影响帧率 → USER_INTERACTIVE
    // - VulkanWorker:  GPU 命令提交线程 → DEADLINE_REQUEST
    // - Pipeline/Shader workers: 着色器编译 → USER_INITIATED
    // - citra:Log: 日志线程 → BACKGROUND (不影响性能)
    {
        // 使用 dlsym 动态加载 QoS 函数，避免 citraLib 静态库直接链接 libqos.so
        // 运行时 citra_ohos.so 已链接 libqos.so，符号可用
        // C++11 保证 static 局部变量初始化的线程安全性
        using QoSSetFunc = int (*)(int);
        static const QoSSetFunc setQoS =
            reinterpret_cast<QoSSetFunc>(dlsym(RTLD_DEFAULT, "OH_QoS_SetThreadQoS"));
        if (setQoS && name) {
            // QoS_Level 枚举值: BACKGROUND=0, UTILITY=1, DEFAULT=2,
            //                    USER_INITIATED=3, DEADLINE_REQUEST=4, USER_INTERACTIVE=5
            int qosLevel = 4; // 默认 DEADLINE_REQUEST
            std::string threadName(name);
            if (threadName.find("Present") != std::string::npos ||
                threadName.find("Render") != std::string::npos) {
                qosLevel = 5; // QOS_USER_INTERACTIVE
            } else if (threadName.find("Worker") != std::string::npos ||
                       threadName.find("Scheduler") != std::string::npos) {
                qosLevel = 4; // QOS_DEADLINE_REQUEST
            } else if (threadName.find("Pipeline") != std::string::npos ||
                       threadName.find("Shader") != std::string::npos) {
                qosLevel = 3; // QOS_USER_INITIATED
            } else if (threadName.find("Log") != std::string::npos ||
                       threadName.find("Crash") != std::string::npos ||
                       threadName.find("PlayTime") != std::string::npos) {
                qosLevel = 0; // QOS_BACKGROUND
            }
            setQoS(qosLevel);
        }
    }
#endif
}
#endif

#if defined(_WIN32)
void SetCurrentThreadName(const char*) {
    // Do Nothing on MingW
}
#endif

#endif

} // namespace Common
