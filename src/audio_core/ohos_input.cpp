// Copyright 2026 Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include <algorithm>
#include <cstring>
#include <utility>
#include <vector>
#include <ohaudio/native_audiocapturer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include "audio_core/ohos_input.h"
#include "audio_core/input.h"
#include "common/logging/log.h"
#include "common/threadsafe_queue.h"

namespace AudioCore {

using SampleQueue = Common::SPSCQueue<Samples>;

struct OhosInput::Impl {
    OH_AudioStreamBuilder* builder = nullptr;
    OH_AudioCapturer* capturer = nullptr;

    SampleQueue sample_queue{};
    u8 sample_size_in_bytes = 0;
    bool sampling = false;

    // 对齐 nds ohos_mic：回调内音量放大 2x 并 clamp；样本进 SPSC 队列由 Read() 消费
    static void OnReadData(OH_AudioCapturer* capturer, void* user_data, void* audio_data,
                           int32_t audio_data_size) {
        auto impl = static_cast<Impl*>(user_data);
        if (!impl || audio_data_size <= 0) {
            return;
        }
        const int num_frames = audio_data_size / static_cast<int32_t>(sizeof(s16));
        const s16* input = static_cast<const s16*>(audio_data);

        Samples samples;
        samples.reserve(num_frames * impl->sample_size_in_bytes);
        for (int i = 0; i < num_frames; ++i) {
            const s16 amplified =
                static_cast<s16>(std::clamp(static_cast<int>(input[i]) * 2, -32766, 32767));
            if (impl->sample_size_in_bytes == 1) {
                // 与 cubeb 一致：8bit 输出时把 s16 高位截回 u8
                samples.push_back(static_cast<u8>(static_cast<u16>(amplified) >> 8));
            } else {
                const u8* data = reinterpret_cast<const u8*>(&amplified);
                samples.insert(samples.end(), data, data + sizeof(s16));
            }
        }
        impl->sample_queue.Push(samples);
    }

    static void OnError(OH_AudioCapturer* capturer, void* user_data,
                        OH_AudioStream_Result error) {
        LOG_ERROR(Audio, "Mic capturer stream error: {}", static_cast<int>(error));
    }
};

OhosInput::OhosInput() : impl(std::make_unique<Impl>()) {}

OhosInput::~OhosInput() {
    StopSampling();
}

void OhosInput::StartSampling(const InputParameters& params) {
    if (IsSampling()) {
        return;
    }
    if (params.sign == Signedness::Unsigned) {
        LOG_WARNING(
            Audio,
            "Application requested unsupported unsigned pcm format. Falling back to signed.");
    }

    parameters = params;
    impl->sample_size_in_bytes = params.sample_size / 8;

    auto create_builder = [&]() -> bool {
        if (OH_AudioStreamBuilder_Create(&impl->builder, AUDIOSTREAM_TYPE_CAPTURER) !=
                AUDIOSTREAM_SUCCESS ||
            !impl->builder) {
            LOG_CRITICAL(Audio, "Failed to create audio stream builder");
            return false;
        }
        OH_AudioStreamBuilder_SetChannelCount(impl->builder, 1);
        OH_AudioStreamBuilder_SetSampleFormat(impl->builder, AUDIOSTREAM_SAMPLE_S16LE);
        OH_AudioStreamBuilder_SetEncodingType(impl->builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
        OH_AudioStreamBuilder_SetCapturerInfo(impl->builder, AUDIOSTREAM_SOURCE_TYPE_MIC);
        OH_AudioStreamBuilder_SetCapturerReadDataCallback(impl->builder, Impl::OnReadData,
                                                          impl.get());
        OH_AudioStreamBuilder_SetCapturerErrorCallback(impl->builder, Impl::OnError, nullptr);
        return true;
    };
    auto generate = [&](u32 rate) -> bool {
        OH_AudioStreamBuilder_SetSamplingRate(impl->builder, rate);
        return OH_AudioStreamBuilder_GenerateCapturer(impl->builder, &impl->capturer) ==
                   AUDIOSTREAM_SUCCESS &&
               impl->capturer;
    };
    auto destroy_builder = [&]() {
        if (impl->builder) {
            OH_AudioStreamBuilder_Destroy(impl->builder);
            impl->builder = nullptr;
        }
    };

    if (!create_builder()) {
        return;
    }
    // 3DS 麦克风采样率非标准值时部分设备拒绝，回退 44100（与 cubeb 的 TODO resample 同策略）
    if (!generate(params.sample_rate)) {
        if (params.sample_rate == 44100) {
            LOG_CRITICAL(Audio, "Failed to generate mic capturer");
            StopSampling();
            return;
        }
        destroy_builder();
        if (!create_builder() || !generate(44100)) {
            LOG_CRITICAL(Audio, "Failed to generate mic capturer at 44100Hz");
            StopSampling();
            return;
        }
    }

    if (OH_AudioCapturer_Start(impl->capturer) != AUDIOSTREAM_SUCCESS) {
        LOG_CRITICAL(Audio, "Failed to start mic capturer");
        StopSampling();
        return;
    }
    impl->sampling = true;
}

void OhosInput::StopSampling() {
    if (impl->capturer) {
        OH_AudioCapturer_Release(impl->capturer);
        impl->capturer = nullptr;
    }
    if (impl->builder) {
        OH_AudioStreamBuilder_Destroy(impl->builder);
        impl->builder = nullptr;
    }
    impl->sampling = false;
}

bool OhosInput::IsSampling() {
    return impl->sampling;
}

void OhosInput::AdjustSampleRate(u32 sample_rate) {
    if (!IsSampling()) {
        return;
    }

    auto new_parameters = parameters;
    new_parameters.sample_rate = sample_rate;
    StopSampling();
    StartSampling(new_parameters);
}

Samples OhosInput::Read() {
    if (!IsSampling()) {
        return {};
    }

    Samples samples{};
    Samples queue;
    while (impl->sample_queue.Pop(queue)) {
        samples.insert(samples.end(), queue.begin(), queue.end());
    }
    return samples;
}

std::vector<std::string> ListOhosInputDevices() {
    return {"OHOS Microphone"};
}

} // namespace AudioCore
