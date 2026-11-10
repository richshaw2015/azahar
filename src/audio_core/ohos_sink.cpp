// Copyright Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#include "audio_core/ohos_sink.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <functional>
#include <vector>

#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audio_session_manager.h>

#include "audio_core/audio_types.h"
#include "common/logging/log.h"

namespace AudioCore {
namespace {

constexpr int kOutputSampleRate = 48000;
constexpr int kOutputChannels = 2;
constexpr int kCallbackFrames = 512;
constexpr double kInputFramesPerOutputFrame =
    static_cast<double>(native_sample_rate) / static_cast<double>(kOutputSampleRate);

std::array<s16, 2> LerpFrame(const std::array<s16, 2>& a, const std::array<s16, 2>& b,
                             double t) {
    const auto lerp_channel = [t](s16 lhs, s16 rhs) {
        const double value = static_cast<double>(lhs) +
                             (static_cast<double>(rhs) - static_cast<double>(lhs)) * t;
        return static_cast<s16>(std::clamp(value, -32768.0, 32767.0));
    };
    return {lerp_channel(a[0], b[0]), lerp_channel(a[1], b[1])};
}

} // namespace

// OHAudio 回调为拉模式（与 cubeb_sink 同构）：SetCallback 存下 DspInterface::OutputCallback，
// OnWriteData 按需调用它产出 native-rate(32728Hz) 帧，再线性插值重采样到 48k。
// 因此 DspInterface 的整条拉取链路全部生效：fifo 缓冲、TimeStretcher 动态纠偏
// （enable_audio_stretching 设置）、DrainFifoBacklog 积压冲刷、欠载末帧保持、音量。
// 不再使用 ImmediateSubmission 直推 + 自有环形缓冲（积压不会自愈，stall 后形成恒定滞后）。
struct OhosSink::Impl {
    OH_AudioStreamBuilder* builder = nullptr;
    OH_AudioRenderer* renderer = nullptr;
    // AudioSession：激活 CONCURRENCY_MIX_WITH_OTHERS 后游戏音频可与其他应用
    // （语音通话/媒体）并发混音，不再被其他应用打断（对齐 retro/ppsspp）。
    // 须在 GenerateRenderer 之前激活，renderer 才继承并发策略
    OH_AudioSessionManager* session_mgr = nullptr;
    bool session_active = false;

    // DspInterface::OutputCallback；完整填满请求的 native-rate 立体声帧。
    // cb 在 renderer Start 之后才赋值，回调线程经 cb_set 就绪标志读取，避免竞争
    std::function<void(s16*, std::size_t)> cb;
    std::atomic_bool cb_set{false};

    std::atomic_bool interrupted{false};
    std::atomic_bool paused{false};
    std::atomic_bool reset_resampler{false};
    std::atomic_bool shutting_down{false};

    // native → 48k 重采样适配状态（仅音频回调线程访问）：
    // native_buf 暂存 cb 拉取的待消费帧，相位推进做线性插值
    std::vector<std::array<s16, 2>> native_buf;
    std::size_t native_read = 0;
    std::array<s16, 2> prev_frame{};
    std::array<s16, 2> cur_frame{};
    bool has_frames = false;
    double resample_phase = 0.0;

    bool Initialize();
    void Shutdown();
    void ProduceOutput(s16* output, std::size_t out_frames);

    static OH_AudioData_Callback_Result OnWriteData(OH_AudioRenderer* renderer, void* user_data,
                                                    void* audio_data, int32_t audio_data_size);
    static void OnInterrupt(OH_AudioRenderer* renderer, void* user_data,
                            OH_AudioInterrupt_ForceType type, OH_AudioInterrupt_Hint hint);
    static void OnError(OH_AudioRenderer* renderer, void* user_data, OH_AudioStream_Result error);
    static int32_t OnSessionDeactivated(OH_AudioSession_DeactivatedEvent event);
};

OhosSink::OhosSink(std::string_view device_id) : impl{std::make_unique<Impl>()} {
    if (!device_id.empty() && device_id != auto_device_name) {
        LOG_WARNING(Audio_Sink,
                    "OHOS audio device selection is not implemented; using default output.");
    }
    if (!impl->Initialize()) {
        LOG_CRITICAL(Audio_Sink, "Failed to initialize OHAudio sink.");
    }
}

OhosSink::~OhosSink() {
    if (impl) {
        impl->Shutdown();
    }
}

unsigned int OhosSink::GetNativeSampleRate() const {
    // cb 产出的是 native-rate 帧；DspInterface 用它设置 TimeStretcher 的输出采样率
    return native_sample_rate;
}

void OhosSink::SetCallback(std::function<void(s16*, std::size_t)> cb) {
    impl->cb = std::move(cb);
    impl->cb_set.store(true, std::memory_order_release);
}

void OhosSink::Pause() {
    if (!impl || !impl->renderer || impl->paused.exchange(true)) {
        return;
    }
    const OH_AudioStream_Result pause_result = OH_AudioRenderer_Pause(impl->renderer);
    if (pause_result != AUDIOSTREAM_SUCCESS) {
        LOG_ERROR(Audio_Sink, "Failed to pause OHAudio renderer: {}", pause_result);
    }
    const OH_AudioStream_Result flush_result = OH_AudioRenderer_Flush(impl->renderer);
    if (flush_result != AUDIOSTREAM_SUCCESS) {
        LOG_ERROR(Audio_Sink, "Failed to flush OHAudio renderer during pause: {}", flush_result);
    }
    impl->reset_resampler = true;
}

void OhosSink::Resume() {
    if (!impl || !impl->renderer || !impl->paused.load()) {
        return;
    }
    const OH_AudioStream_Result flush_result = OH_AudioRenderer_Flush(impl->renderer);
    if (flush_result != AUDIOSTREAM_SUCCESS) {
        LOG_ERROR(Audio_Sink, "Failed to flush OHAudio renderer before resume: {}", flush_result);
    }
    const OH_AudioStream_Result start_result = OH_AudioRenderer_Start(impl->renderer);
    if (start_result != AUDIOSTREAM_SUCCESS) {
        LOG_ERROR(Audio_Sink, "Failed to resume OHAudio renderer: {}", start_result);
        return;
    }
    impl->paused = false;
}

bool OhosSink::Impl::Initialize() {
    OH_AudioStream_Result result =
        OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER);
    if (result != AUDIOSTREAM_SUCCESS || !builder) {
        LOG_CRITICAL(Audio_Sink, "OH_AudioStreamBuilder_Create failed: {}", result);
        return false;
    }

    OH_AudioStreamBuilder_SetSamplingRate(builder, kOutputSampleRate);
    OH_AudioStreamBuilder_SetChannelCount(builder, kOutputChannels);
    OH_AudioStreamBuilder_SetSampleFormat(builder, AUDIOSTREAM_SAMPLE_S16LE);
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
    OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_GAME);
    OH_AudioStreamBuilder_SetFrameSizeInCallback(builder, kCallbackFrames);
    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, &Impl::OnWriteData, this);
    OH_AudioStreamBuilder_SetRendererInterruptCallback(builder, &Impl::OnInterrupt, this);
    OH_AudioStreamBuilder_SetRendererErrorCallback(builder, &Impl::OnError, this);

    // 激活 AudioSession 后再建 renderer，并发策略才会应用到本流
    if (OH_AudioManager_GetAudioSessionManager(&session_mgr) == AUDIOCOMMON_RESULT_SUCCESS &&
        session_mgr) {
        OH_AudioSessionManager_SetScene(session_mgr, AUDIO_SESSION_SCENE_GAME);
        OH_AudioSessionManager_RegisterSessionDeactivatedCallback(
            session_mgr, &Impl::OnSessionDeactivated);
        // MIX_WITH_OTHERS 允许与其他应用的音频混音并发，但系统仍可随时抢占/停用本会话
        //（来电、闹钟等）；抢占/恢复经流级 OnInterrupt 与会话 OnSessionDeactivated 上报
        OH_AudioSession_Strategy strategy{CONCURRENCY_MIX_WITH_OTHERS};
        const OH_AudioCommon_Result activate_result =
            OH_AudioSessionManager_ActivateAudioSession(session_mgr, &strategy);
        if (activate_result == AUDIOCOMMON_RESULT_SUCCESS) {
            session_active = true;
        } else {
            // 并发激活失败不致命：退回默认独占语义继续建流
            LOG_WARNING(Audio_Sink, "AudioSession activate failed: {}", activate_result);
        }
    } else {
        LOG_WARNING(Audio_Sink, "AudioSessionManager unavailable, default audio focus");
    }

    result = OH_AudioStreamBuilder_GenerateRenderer(builder, &renderer);
    if (result != AUDIOSTREAM_SUCCESS || !renderer) {
        LOG_CRITICAL(Audio_Sink, "OH_AudioStreamBuilder_GenerateRenderer failed: {}", result);
        Shutdown();
        return false;
    }

    result = OH_AudioRenderer_Start(renderer);
    if (result != AUDIOSTREAM_SUCCESS) {
        LOG_CRITICAL(Audio_Sink, "OH_AudioRenderer_Start failed: {}", result);
        Shutdown();
        return false;
    }

    LOG_INFO(Audio_Sink, "OHAudio sink started: {} Hz, {} callback frames", kOutputSampleRate,
             kCallbackFrames);
    return true;
}

void OhosSink::Impl::Shutdown() {
    shutting_down.store(true);
    if (renderer) {
        OH_AudioRenderer_Stop(renderer);
        OH_AudioRenderer_Release(renderer);
        renderer = nullptr;
    }
    if (builder) {
        OH_AudioStreamBuilder_Destroy(builder);
        builder = nullptr;
    }
    if (session_mgr) {
        OH_AudioSessionManager_UnregisterSessionDeactivatedCallback(
            session_mgr, &Impl::OnSessionDeactivated);
        if (session_active) {
            OH_AudioSessionManager_DeactivateAudioSession(session_mgr);
            session_active = false;
        }
        session_mgr = nullptr;
    }
}

// 仅音频回调线程调用。经 cb 拉取 native-rate 帧，按相位线性插值产出 out_frames 个 48k 帧。
// cb（OutputCallback）保证完整填满请求帧数（内部有欠载末帧保持），故不需要欠载兜底。
void OhosSink::Impl::ProduceOutput(s16* output, std::size_t out_frames) {
    if (reset_resampler.exchange(false)) {
        native_buf.clear();
        native_read = 0;
        has_frames = false;
        resample_phase = 0.0;
    }

    // 每个输出帧最多推进一个 native 帧对，加上相位余量预留 4 帧
    const std::size_t pending = native_buf.size() - native_read;
    const std::size_t want =
        static_cast<std::size_t>(std::ceil(out_frames * kInputFramesPerOutputFrame)) + 4;
    if (pending < want) {
        const std::size_t old_size = native_buf.size();
        native_buf.resize(old_size + (want - pending));
        cb(reinterpret_cast<s16*>(native_buf.data() + old_size), want - pending);
    }

    const auto pull_native = [this]() -> std::array<s16, 2> {
        return native_read < native_buf.size() ? native_buf[native_read++]
                                               : std::array<s16, 2>{};
    };

    if (!has_frames) {
        prev_frame = pull_native();
        cur_frame = pull_native();
        has_frames = true;
    }

    for (std::size_t i = 0; i < out_frames; ++i) {
        if (resample_phase > 1.0) {
            resample_phase -= 1.0;
            prev_frame = cur_frame;
            cur_frame = pull_native();
        }
        const std::array<s16, 2> out = LerpFrame(prev_frame, cur_frame, resample_phase);
        output[i * 2] = out[0];
        output[i * 2 + 1] = out[1];
        resample_phase += kInputFramesPerOutputFrame;
    }

    if (native_read > 0) {
        native_buf.erase(native_buf.begin(), native_buf.begin() + native_read);
        native_read = 0;
    }
}

OH_AudioData_Callback_Result OhosSink::Impl::OnWriteData(OH_AudioRenderer* renderer,
                                                         void* user_data, void* audio_data,
                                                         int32_t audio_data_size) {
    auto* impl = static_cast<Impl*>(user_data);
    if (!impl || !audio_data || audio_data_size <= 0) {
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }

    std::memset(audio_data, 0, static_cast<std::size_t>(audio_data_size));
    // 暂停/中断/关闭期间输出静音；fifo 侧的积压由 DrainFifoBacklog 自愈
    if (impl->paused.load() || impl->interrupted.load() || impl->shutting_down.load() ||
        !impl->cb_set.load(std::memory_order_acquire)) {
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    const std::size_t frames =
        static_cast<std::size_t>(audio_data_size) / (kOutputChannels * sizeof(s16));
    impl->ProduceOutput(static_cast<s16*>(audio_data), frames);
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

void OhosSink::Impl::OnInterrupt(OH_AudioRenderer* renderer, void* user_data,
                                 OH_AudioInterrupt_ForceType type,
                                 OH_AudioInterrupt_Hint hint) {
    auto* impl = static_cast<Impl*>(user_data);
    if (!impl) {
        return;
    }

    switch (hint) {
    case AUDIOSTREAM_INTERRUPT_HINT_PAUSE:
    case AUDIOSTREAM_INTERRUPT_HINT_STOP:
        impl->interrupted.store(true);
        break;
    case AUDIOSTREAM_INTERRUPT_HINT_RESUME:
        impl->interrupted.store(false);
        impl->reset_resampler.store(true);
        if (type == AUDIOSTREAM_INTERRUPT_SHARE && renderer) {
            OH_AudioRenderer_Start(renderer);
        }
        break;
    default:
        break;
    }
}

void OhosSink::Impl::OnError(OH_AudioRenderer* renderer, void* user_data,
                             OH_AudioStream_Result error) {
    LOG_ERROR(Audio_Sink, "OHAudio renderer error: {}", error);
}

int32_t OhosSink::Impl::OnSessionDeactivated(OH_AudioSession_DeactivatedEvent event) {
    // 会话被系统停用（如来电抢走焦点）；流级暂停/恢复仍走 OnInterrupt
    LOG_WARNING(Audio_Sink, "OHAudio session deactivated, reason={}",
                static_cast<int>(event.reason));
    return 0;
}

std::vector<std::string> ListOhosSinkDevices() {
    return {auto_device_name};
}

} // namespace AudioCore
