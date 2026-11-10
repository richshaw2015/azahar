// Copyright 2026 Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#pragma once

#include "audio_core/input.h"

namespace AudioCore {

// 吹气模拟：循环播放 melonDS mic_blow 预烘焙波形，供吹气检测类游戏使用。
// 移植自 ../nds melonLib mic_blow.h，语义与 melonDS MicSource::Blow 一致
// （游戏请求麦克风采样期间持续输出吹气信号）。
class BlowInput final : public Input {
public:
    BlowInput() = default;
    ~BlowInput() = default;

    void StartSampling(const InputParameters& params) {
        parameters = params;
        offset_ = 0;
        is_sampling = true;
    }

    void StopSampling() {
        is_sampling = false;
    }

    bool IsSampling() {
        return is_sampling;
    }

    void AdjustSampleRate(u32 sample_rate) {}

    Samples Read();

private:
    bool is_sampling = false;
    u32 offset_ = 0;
};

} // namespace AudioCore
