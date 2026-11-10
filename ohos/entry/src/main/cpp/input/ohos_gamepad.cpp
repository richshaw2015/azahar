#include "input/ohos_gamepad.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <mutex>
#include <optional>
#include <utility>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <GameControllerKit/game_controller_type.h>
#include <GameControllerKit/game_device.h>
#include <GameControllerKit/game_device_event.h>
#include <GameControllerKit/game_pad.h>
#include <GameControllerKit/game_pad_event.h>
#include <hilog/log.h>
#include <json.hpp>

#include "common/settings.h"
#include "core/azahar_core_bridge.h"
#include "input/ohos_input.h"

namespace Azahar::Ohos::Gamepad {
namespace {

constexpr unsigned int kLogDomain = 0x0001;
constexpr const char* kLogTag = "Azahar_Gamepad";

// Physical axis sources selectable for each 3DS analog axis.
constexpr int32_t kAxisSourceNone = -1;
constexpr int32_t kAxisSourceLeftStick = 0;
constexpr int32_t kAxisSourceRightStick = 1;
constexpr int32_t kAxisSourceDpadHat = 2;

// OHOS multimodal key codes emitted by GameControllerKit button events.
constexpr int32_t kCodeDpadUp = 2012;
constexpr int32_t kCodeDpadDown = 2013;
constexpr int32_t kCodeDpadLeft = 2014;
constexpr int32_t kCodeDpadRight = 2015;

constexpr float kHatThreshold = 0.5f;
constexpr float kCaptureAxisThreshold = 0.6f;
constexpr double kMaxDeadZonePercent = 50.0;

// Captured axis bindings are reported to ArkTS packed as
// 30000 + source*100 + component*10 + dir (dir: 0 = negative, 1 = positive),
// so they cannot collide with real multimodal button codes.
constexpr int32_t kAxisCaptureCodeBase = 30000;

std::atomic_bool g_initialized{false};

// One 3DS analog axis bound to one component of one physical source.
// Output value = source_component * sign.
struct AxisBinding {
    int32_t source = kAxisSourceNone;
    int32_t component = 0; // 0 = x, 1 = y
    int32_t sign = 1;
};

// Runtime input mapping, rebuilt by ApplyConfig. Physical code -> 3DS buttons
// (one code may press several buttons via the combo feature).
struct MappingState {
    std::unordered_map<int32_t, std::vector<int32_t>> buttons;
    AxisBinding circlepad_h{kAxisSourceLeftStick, 0, 1};
    AxisBinding circlepad_v{kAxisSourceLeftStick, 1, 1};
    AxisBinding cstick_h{kAxisSourceRightStick, 0, 1};
    AxisBinding cstick_v{kAxisSourceRightStick, 1, 1};
    // 3DS dpad directions driven by a physical axis (Android "D-Pad (Axis)").
    // Unbound by default; unlike the analog bindings these emit button events.
    AxisBinding dpad_v;
    AxisBinding dpad_h;
};

std::mutex g_map_mutex;
MappingState g_map{};
// Latest computed values for each 3DS analog axis; needed because the two axes
// of one analog may be bound to different physical sources.
float g_circle_x = 0.0f;
float g_circle_y = 0.0f;
float g_cstick_x = 0.0f;
float g_cstick_y = 0.0f;
// Current pressed direction (-1/0/+1) of each dpad axis binding, for edges.
int32_t g_dpad_axis_dirs[2] = {0, 0};
// Physical button codes whose press reached the mapping and have not been
// released. Combined with g_map + g_dpad_axis_dirs this derives which 3DS
// buttons a gamepad currently holds (guarded by g_map_mutex).
std::unordered_set<int32_t> g_held_codes;
std::atomic<float> g_deadzone{0.10f};

// Binding capture state for the settings page.
std::atomic_bool g_capture_active{false};
std::atomic_bool g_capture_axis{false};
std::atomic<int32_t> g_captured_code{-1};
std::atomic<int32_t> g_swallow_up_code{-1};

// One button edge for the tester's event log / coverage tracking.
struct TestEvent {
    uint32_t seq = 0;
    int32_t code = 0;
    bool down = false;
    int64_t time_ms = 0;
};
constexpr size_t kTestEventCapacity = 64;

// Raw input snapshot for the settings-page gamepad tester tab. Written before
// mapping/capture handling so every physical event is visible to the tester.
struct TestState {
    std::unordered_set<int32_t> pressed;
    float lx = 0.0f;
    float ly = 0.0f;
    float rx = 0.0f;
    float ry = 0.0f;
    float hat_x = 0.0f;
    float hat_y = 0.0f;
    float lt = 0.0f; // analog trigger travel, 0..1
    float rt = 0.0f;
    int32_t last_code = -1;
    // Ring buffer of button edges; seq increases monotonically so the UI can
    // consume incrementally and never miss taps shorter than its poll period.
    std::vector<TestEvent> events;
    uint32_t next_seq = 1;
};
std::mutex g_test_mutex;
TestState g_test;
std::string g_device_name;
// Any delivered input event implies a connected pad (device ONLINE events only
// fire on hot-plug, not for pads already attached at app start).
std::atomic_bool g_device_seen{false};

int64_t NowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

void RecordButtonForTest(int32_t code, bool is_down) {
    g_device_seen.store(true);
    std::lock_guard<std::mutex> lock(g_test_mutex);
    // Only log real edges: the hat path re-dispatches dpad codes on every axis
    // event, which would otherwise flood the log with duplicate releases.
    const bool was_down = g_test.pressed.count(code) > 0;
    if (was_down == is_down) {
        return;
    }
    if (is_down) {
        g_test.pressed.insert(code);
        g_test.last_code = code;
    } else {
        g_test.pressed.erase(code);
    }
    if (g_test.events.size() >= kTestEventCapacity) {
        g_test.events.erase(g_test.events.begin());
    }
    g_test.events.push_back({g_test.next_seq++, code, is_down, NowMs()});
}

void RecordTriggerForTest(bool left, double value) {
    g_device_seen.store(true);
    // GCK reports [-1, 1]; some pads rest at -1, others at 0. Map both to 0..1.
    float v = static_cast<float>(value);
    v = v < 0.0f ? (v + 1.0f) * 0.5f : v;
    std::lock_guard<std::mutex> lock(g_test_mutex);
    (left ? g_test.lt : g_test.rt) = std::clamp(v, 0.0f, 1.0f);
}

std::string ReadDeviceName(const GameDevice_DeviceInfo* info) {
    char* name = nullptr;
    std::string result;
    if (info && OH_GameDevice_DeviceInfo_GetName(info, &name) == GAME_CONTROLLER_SUCCESS &&
        name) {
        result = name;
        std::free(name);
    }
    return result;
}

// Pads already attached at app start never fire ONLINE, so enumerate them.
void RefreshConnectedDevice() {
    GameDevice_AllDeviceInfos* all = nullptr;
    if (OH_GameDevice_GetAllDeviceInfos(&all) != GAME_CONTROLLER_SUCCESS || !all) {
        return;
    }
    int32_t count = 0;
    std::string name;
    if (OH_GameDevice_AllDeviceInfos_GetCount(all, &count) == GAME_CONTROLLER_SUCCESS &&
        count > 0) {
        GameDevice_DeviceInfo* info = nullptr;
        if (OH_GameDevice_AllDeviceInfos_GetDeviceInfo(all, 0, &info) ==
                GAME_CONTROLLER_SUCCESS &&
            info) {
            name = ReadDeviceName(info);
            OH_GameDevice_DestroyDeviceInfo(&info);
        }
    }
    OH_GameDevice_DestroyAllDeviceInfos(&all);
    if (count > 0) {
        g_device_seen.store(true);
        std::lock_guard<std::mutex> lock(g_test_mutex);
        g_device_name = name;
    }
}

void RecordAxisForTest(int32_t source, double x, double y) {
    g_device_seen.store(true);
    const float fx = std::clamp(static_cast<float>(x), -1.0f, 1.0f);
    const float fy = std::clamp(static_cast<float>(y), -1.0f, 1.0f);
    std::lock_guard<std::mutex> lock(g_test_mutex);
    if (source == kAxisSourceLeftStick) {
        g_test.lx = fx;
        g_test.ly = fy;
    } else if (source == kAxisSourceRightStick) {
        g_test.rx = fx;
        g_test.ry = fy;
    } else {
        g_test.hat_x = fx;
        g_test.hat_y = fy;
    }
}

std::unordered_map<int32_t, std::vector<int32_t>> DefaultButtonMap() {
    namespace NB = Settings::NativeButton;
    return {
        {kCodeDpadUp, {NB::Up}},       {kCodeDpadDown, {NB::Down}},
        {kCodeDpadLeft, {NB::Left}},   {kCodeDpadRight, {NB::Right}},
        {2301, {NB::A}},               {2302, {NB::B}},
        {2304, {NB::X}},               {2305, {NB::Y}},
        {2307, {NB::L}},               {2308, {NB::R}},
        {2309, {NB::ZL}},              {2310, {NB::ZR}},
        {2311, {NB::Select}},          {2312, {NB::Start}},
        {2313, {NB::Home}},            // BUTTON_MODE: Guide/Home key
    };
}

std::optional<std::string> ConfigString(const std::unordered_map<std::string, ConfigValue>& config,
                                        const char* key) {
    const auto it = config.find(key);
    if (it == config.end() || !std::holds_alternative<std::string>(it->second)) {
        return std::nullopt;
    }
    return std::get<std::string>(it->second);
}

std::optional<double> ConfigNumber(const std::unordered_map<std::string, ConfigValue>& config,
                                   const char* key) {
    const auto it = config.find(key);
    if (it != config.end() && std::holds_alternative<double>(it->second)) {
        return std::get<double>(it->second);
    }
    if (it != config.end() && std::holds_alternative<bool>(it->second)) {
        return std::get<bool>(it->second) ? 1.0 : 0.0;
    }
    return std::nullopt;
}

void AddButtonBinding(MappingState& state, int32_t physical_code, int32_t native_button) {
    if (physical_code <= 0 || native_button < 0 ||
        native_button >= Settings::NativeButton::NumButtons) {
        return;
    }
    std::vector<int32_t>& targets = state.buttons[physical_code];
    if (std::find(targets.begin(), targets.end(), native_button) == targets.end()) {
        targets.push_back(native_button);
    }
}

// Parses one axis binding entry: [source, component, sign] or -1 for unbound.
AxisBinding AxisBindingFromJson(const nlohmann::json& json, const char* name,
                                const AxisBinding& fallback) {
    const auto it = json.find(name);
    if (it == json.end()) {
        return fallback;
    }
    if (it->is_number_integer() && it->get<int32_t>() < 0) {
        AxisBinding unbound;
        return unbound;
    }
    if (it->is_array() && it->size() == 3) {
        const int32_t source = (*it)[0].get<int32_t>();
        const int32_t component = (*it)[1].get<int32_t>();
        const int32_t sign = (*it)[2].get<int32_t>();
        if (source >= kAxisSourceLeftStick && source <= kAxisSourceDpadHat &&
            (component == 0 || component == 1) && (sign == 1 || sign == -1)) {
            return {source, component, sign};
        }
    }
    return fallback;
}

// 对齐 SDL 端 SDLAnalog::GetStatus 的圆形死区：按向量模长截断，超过死区后沿
// 原方向把模长重缩放到 [0,1]，输出从 0 平滑起跳（方形逐轴截断会在死区边界
// 产生 0→deadzone 的跳变，且对角方向死区形状不一致）。
std::pair<float, float> NormalizeAxes(double x, double y, float deadzone) {
    const float nx = std::clamp(static_cast<float>(x), -1.0f, 1.0f);
    const float ny = std::clamp(static_cast<float>(y), -1.0f, 1.0f);
    const float r = std::sqrt(nx * nx + ny * ny);
    if (r <= deadzone) {
        return {0.0f, 0.0f};
    }
    const float scale = (r - deadzone) / ((1.0f - deadzone) * r);
    return {nx * scale, ny * scale};
}

void SendAnalog(int32_t analog_code, float x, float y) {
    CoreBridge::Get().SendAnalogEvent(analog_code, x, y);
}

// Routes a physical button/axis-code press through the configured map.
void DispatchPhysicalButton(int32_t button_code, bool is_down) {
    RecordButtonForTest(button_code, is_down);
    if (is_down && g_capture_active.load()) {
        // In axis-capture mode a button press is swallowed but not recorded.
        if (g_capture_axis.load()) {
            g_swallow_up_code.store(button_code);
            return;
        }
        g_captured_code.store(button_code);
        g_capture_active.store(false);
        g_swallow_up_code.store(button_code);
        return;
    }
    if (!is_down && button_code == g_swallow_up_code.load()) {
        g_swallow_up_code.store(-1);
        return;
    }

    std::lock_guard<std::mutex> lock(g_map_mutex);
    if (is_down) {
        g_held_codes.insert(button_code);
    } else {
        g_held_codes.erase(button_code);
    }
    const auto it = g_map.buttons.find(button_code);
    if (it == g_map.buttons.end()) {
        return;
    }
    for (const int32_t native_key : it->second) {
        CoreBridge::Get().SendKeyEvent(native_key, is_down);
    }
}

// Records the strongest axis component of an axis event while axis capture is
// armed. Returns true when the event was consumed by the capture.
bool TryCaptureAxis(int32_t source, float x, float y) {
    if (!g_capture_active.load() || !g_capture_axis.load()) {
        return false;
    }
    const int32_t component = std::abs(x) >= std::abs(y) ? 0 : 1;
    const float moved = component == 0 ? x : y;
    if (std::abs(moved) <= kCaptureAxisThreshold) {
        return true; // still swallow noise while armed
    }
    g_captured_code.store(kAxisCaptureCodeBase + source * 100 + component * 10 +
                          (moved > 0.0f ? 1 : 0));
    g_capture_active.store(false);
    return true;
}

// Feeds a physical stick/dpad-hat axis pair into whichever 3DS analog axes bind
// it. While any capture is armed the feed is swallowed instead.
void DispatchAxisSource(int32_t source, float x, float y) {
    if (g_capture_active.load()) {
        if (g_capture_axis.load()) {
            TryCaptureAxis(source, x, y);
        } else if (source == kAxisSourceDpadHat) {
            // Button-mode capture still wants the dpad hat converted into buttons.
            DispatchPhysicalButton(kCodeDpadLeft, x < -kHatThreshold);
            DispatchPhysicalButton(kCodeDpadRight, x > kHatThreshold);
            DispatchPhysicalButton(kCodeDpadUp, y < -kHatThreshold);
            DispatchPhysicalButton(kCodeDpadDown, y > kHatThreshold);
        }
        return;
    }

    std::lock_guard<std::mutex> lock(g_map_mutex);
    const AxisBinding* bindings[4] = {&g_map.circlepad_h, &g_map.circlepad_v, &g_map.cstick_h,
                                     &g_map.cstick_v};
    float* targets[4] = {&g_circle_x, &g_circle_y, &g_cstick_x, &g_cstick_y};
    bool circlepad_changed = false;
    bool cstick_changed = false;
    for (int i = 0; i < 4; i++) {
        if (bindings[i]->source == source) {
            *targets[i] =
                (bindings[i]->component == 0 ? x : y) * static_cast<float>(bindings[i]->sign);
            if (i < 2) {
                circlepad_changed = true;
            } else {
                cstick_changed = true;
            }
        }
    }
    if (circlepad_changed) {
        SendAnalog(Input::kCirclePadAnalog, g_circle_x, g_circle_y);
    }
    if (cstick_changed) {
        SendAnalog(Input::kCStickAnalog, g_cstick_x, g_cstick_y);
    }

    // 十字方向键（轴）绑定：轴方向越过阈值时直接产生 3DS 十字键按下/松开
    // （对齐 Android 的 D-Pad (Axis)，不经 buttons 映射表——输出是 3DS 键级）。
    const AxisBinding* dpad_bindings[2] = {&g_map.dpad_v, &g_map.dpad_h};
    for (int i = 0; i < 2; i++) {
        const AxisBinding& binding = *dpad_bindings[i];
        if (binding.source != source) {
            continue;
        }
        const float moved =
            (binding.component == 0 ? x : y) * static_cast<float>(binding.sign);
        const int32_t dir = moved < -kHatThreshold ? -1 : (moved > kHatThreshold ? 1 : 0);
        if (dir == g_dpad_axis_dirs[i]) {
            continue;
        }
        const int32_t neg_button =
            i == 0 ? Settings::NativeButton::Up : Settings::NativeButton::Left;
        const int32_t pos_button =
            i == 0 ? Settings::NativeButton::Down : Settings::NativeButton::Right;
        if (g_dpad_axis_dirs[i] != 0) {
            CoreBridge::Get().SendKeyEvent(g_dpad_axis_dirs[i] < 0 ? neg_button : pos_button,
                                         false);
        }
        if (dir != 0) {
            CoreBridge::Get().SendKeyEvent(dir < 0 ? neg_button : pos_button, true);
        }
        g_dpad_axis_dirs[i] = dir;
    }
}

void ReleaseAllInputs() {
    std::lock_guard<std::mutex> lock(g_map_mutex);
    g_held_codes.clear();
    for (const auto& [code, targets] : g_map.buttons) {
        for (const int32_t native_key : targets) {
            CoreBridge::Get().SendKeyEvent(native_key, false);
        }
    }
    g_circle_x = g_circle_y = g_cstick_x = g_cstick_y = 0.0f;
    SendAnalog(Input::kCirclePadAnalog, 0.0f, 0.0f);
    SendAnalog(Input::kCStickAnalog, 0.0f, 0.0f);
    for (int i = 0; i < 2; i++) {
        if (g_dpad_axis_dirs[i] != 0) {
            const int32_t neg_button =
                i == 0 ? Settings::NativeButton::Up : Settings::NativeButton::Left;
            const int32_t pos_button =
                i == 0 ? Settings::NativeButton::Down : Settings::NativeButton::Right;
            CoreBridge::Get().SendKeyEvent(g_dpad_axis_dirs[i] < 0 ? neg_button : pos_button,
                                         false);
            g_dpad_axis_dirs[i] = 0;
        }
    }
}

void HandleButtonEvent(const GamePad_ButtonEvent* event) {
    char* device_id = nullptr;
    if (OH_GamePad_ButtonEvent_GetDeviceId(event, &device_id) != GAME_CONTROLLER_SUCCESS ||
        !device_id) {
        return;
    }

    int32_t button_code = 0;
    GamePad_Button_ActionType action = UP;
    const bool ok =
        OH_GamePad_ButtonEvent_GetButtonCode(event, &button_code) == GAME_CONTROLLER_SUCCESS &&
        OH_GamePad_ButtonEvent_GetButtonAction(event, &action) == GAME_CONTROLLER_SUCCESS;
    std::free(device_id);

    if (ok) {
        DispatchPhysicalButton(button_code, action == DOWN);
    }
}

void OnButtonA(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnButtonB(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnButtonC(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnButtonX(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnButtonY(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnLeftShoulder(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnRightShoulder(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnLeftTriggerButton(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnRightTriggerButton(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnButtonHome(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnButtonMenu(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnDpadUp(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnDpadDown(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnDpadLeft(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnDpadRight(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnLeftThumbstickButton(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}
void OnRightThumbstickButton(const GamePad_ButtonEvent* event) {
    HandleButtonEvent(event);
}

void OnLeftThumbstickAxis(const GamePad_AxisEvent* event) {
    char* device_id = nullptr;
    if (OH_GamePad_AxisEvent_GetDeviceId(event, &device_id) != GAME_CONTROLLER_SUCCESS ||
        !device_id) {
        return;
    }

    double x = 0.0;
    double y = 0.0;
    const bool ok =
        OH_GamePad_AxisEvent_GetXAxisValue(event, &x) == GAME_CONTROLLER_SUCCESS &&
        OH_GamePad_AxisEvent_GetYAxisValue(event, &y) == GAME_CONTROLLER_SUCCESS;
    std::free(device_id);
    if (!ok) {
        return;
    }

    RecordAxisForTest(kAxisSourceLeftStick, x, y);
    const auto [nx, ny] = NormalizeAxes(x, y, g_deadzone.load());
    DispatchAxisSource(kAxisSourceLeftStick, nx, ny);
}

void OnRightThumbstickAxis(const GamePad_AxisEvent* event) {
    char* device_id = nullptr;
    if (OH_GamePad_AxisEvent_GetDeviceId(event, &device_id) != GAME_CONTROLLER_SUCCESS ||
        !device_id) {
        return;
    }

    double x = 0.0;
    double y = 0.0;
    const bool ok =
        OH_GamePad_AxisEvent_GetZAxisValue(event, &x) == GAME_CONTROLLER_SUCCESS &&
        OH_GamePad_AxisEvent_GetRZAxisValue(event, &y) == GAME_CONTROLLER_SUCCESS;
    std::free(device_id);
    if (!ok) {
        return;
    }

    RecordAxisForTest(kAxisSourceRightStick, x, y);
    const auto [nx, ny] = NormalizeAxes(x, y, g_deadzone.load());
    DispatchAxisSource(kAxisSourceRightStick, nx, ny);
}

void OnDpadAxis(const GamePad_AxisEvent* event) {
    char* device_id = nullptr;
    if (OH_GamePad_AxisEvent_GetDeviceId(event, &device_id) != GAME_CONTROLLER_SUCCESS ||
        !device_id) {
        return;
    }

    double x = 0.0;
    double y = 0.0;
    const bool ok =
        OH_GamePad_AxisEvent_GetHatXAxisValue(event, &x) == GAME_CONTROLLER_SUCCESS &&
        OH_GamePad_AxisEvent_GetHatYAxisValue(event, &y) == GAME_CONTROLLER_SUCCESS;
    std::free(device_id);
    if (!ok) {
        return;
    }

    RecordAxisForTest(kAxisSourceDpadHat, x, y);
    const auto [nx, ny] = NormalizeAxes(x, y, g_deadzone.load());

    DispatchAxisSource(kAxisSourceDpadHat, nx, ny);
    if (g_capture_active.load()) {
        return; // DispatchAxisSource already ran the capture-aware hat path.
    }
    // The hat always also feeds the four dpad button codes so remapped dpad
    // bindings work regardless of how the device reports directions.
    DispatchPhysicalButton(kCodeDpadLeft, nx < -kHatThreshold);
    DispatchPhysicalButton(kCodeDpadRight, nx > kHatThreshold);
    DispatchPhysicalButton(kCodeDpadUp, ny < -kHatThreshold);
    DispatchPhysicalButton(kCodeDpadDown, ny > kHatThreshold);
}

// Analog trigger travel for the tester only; the digital trigger button
// monitors still drive the actual ZL/ZR mapping.
void HandleTriggerAxis(const GamePad_AxisEvent* event, bool left) {
    double value = 0.0;
    const bool ok = left
        ? OH_GamePad_AxisEvent_GetBrakeAxisValue(event, &value) == GAME_CONTROLLER_SUCCESS
        : OH_GamePad_AxisEvent_GetGasAxisValue(event, &value) == GAME_CONTROLLER_SUCCESS;
    if (ok) {
        RecordTriggerForTest(left, value);
    }
}

void OnLeftTriggerAxis(const GamePad_AxisEvent* event) {
    HandleTriggerAxis(event, true);
}
void OnRightTriggerAxis(const GamePad_AxisEvent* event) {
    HandleTriggerAxis(event, false);
}

void OnDeviceChanged(const GameDevice_DeviceEvent* event) {
    GameDevice_StatusChangedType type;
    if (OH_GameDevice_DeviceEvent_GetChangedType(event, &type) != GAME_CONTROLLER_SUCCESS) {
        return;
    }
    if (type == OFFLINE) {
        g_device_seen.store(false);
        {
            // Drop live state but keep the event log, matching Steam's tester:
            // reconnecting should not wipe what the user already verified.
            std::lock_guard<std::mutex> lock(g_test_mutex);
            g_test.pressed.clear();
            g_test.lx = g_test.ly = g_test.rx = g_test.ry = 0.0f;
            g_test.hat_x = g_test.hat_y = g_test.lt = g_test.rt = 0.0f;
            g_device_name.clear();
        }
        ReleaseAllInputs();
    } else {
        g_device_seen.store(true);
        GameDevice_DeviceInfo* info = nullptr;
        if (OH_GameDevice_DeviceEvent_GetDeviceInfo(event, &info) == GAME_CONTROLLER_SUCCESS &&
            info) {
            const std::string name = ReadDeviceName(info);
            OH_GameDevice_DestroyDeviceInfo(&info);
            std::lock_guard<std::mutex> lock(g_test_mutex);
            g_device_name = name;
        }
    }
}

} // namespace

void ApplyConfig(const std::unordered_map<std::string, ConfigValue>& config) {
    MappingState next;

    const double deadzone_percent = ConfigNumber(config, "gamepad_deadzone").value_or(10.0);
    g_deadzone.store(static_cast<float>(std::clamp(deadzone_percent, 0.0, kMaxDeadZonePercent)) /
                     100.0f);

    const std::string button_map_str = ConfigString(config, "gamepad_button_map").value_or("");
    if (button_map_str.empty()) {
        next.buttons = DefaultButtonMap();
    } else {
        const nlohmann::json json =
            nlohmann::json::parse(button_map_str, nullptr, /*allow_exceptions=*/false);
        if (json.is_object()) {
            for (const auto& [key, value] : json.items()) {
                if (!value.is_number_integer()) {
                    continue;
                }
                AddButtonBinding(next, value.get<int32_t>(), std::atoi(key.c_str()));
            }
        } else {
            next.buttons = DefaultButtonMap();
        }
    }

    const std::string combo_str = ConfigString(config, "gamepad_combo").value_or("");
    if (!combo_str.empty()) {
        const nlohmann::json json =
            nlohmann::json::parse(combo_str, nullptr, /*allow_exceptions=*/false);
        const int32_t code = json.value("code", -1);
        if (code > 0 && json.contains("buttons") && json["buttons"].is_array()) {
            for (const auto& entry : json["buttons"]) {
                if (entry.is_number_integer()) {
                    AddButtonBinding(next, code, entry.get<int32_t>());
                }
            }
        }
    }

    const std::string axis_map_str = ConfigString(config, "gamepad_axis_map").value_or("");
    if (!axis_map_str.empty()) {
        const nlohmann::json json =
            nlohmann::json::parse(axis_map_str, nullptr, /*allow_exceptions=*/false);
        if (json.is_object()) {
            next.circlepad_h = AxisBindingFromJson(json, "circlepad_h", next.circlepad_h);
            next.circlepad_v = AxisBindingFromJson(json, "circlepad_v", next.circlepad_v);
            next.cstick_h = AxisBindingFromJson(json, "cstick_h", next.cstick_h);
            next.cstick_v = AxisBindingFromJson(json, "cstick_v", next.cstick_v);
            next.dpad_v = AxisBindingFromJson(json, "dpad_v", next.dpad_v);
            next.dpad_h = AxisBindingFromJson(json, "dpad_h", next.dpad_h);

            // Legacy format migration: {"circlepad": src, "cstick": src} whole-
            // stick source selection expands into per-axis bindings.
            const int32_t cp = json.value("circlepad", -2);
            if (cp >= kAxisSourceNone && cp <= kAxisSourceDpadHat) {
                next.circlepad_h = {cp, 0, 1};
                next.circlepad_v = {cp, 1, 1};
            }
            const int32_t cs = json.value("cstick", -2);
            if (cs >= kAxisSourceNone && cs <= kAxisSourceDpadHat) {
                next.cstick_h = {cs, 0, 1};
                next.cstick_v = {cs, 1, 1};
            }
        }
    }

    {
        std::lock_guard<std::mutex> lock(g_map_mutex);
        g_map = std::move(next);
    }
}

void StartInputCapture() {
    g_captured_code.store(-1);
    g_swallow_up_code.store(-1);
    g_capture_axis.store(false);
    g_capture_active.store(true);
}

void StartAxisInputCapture() {
    g_captured_code.store(-1);
    g_swallow_up_code.store(-1);
    g_capture_axis.store(true);
    g_capture_active.store(true);
}

void CancelInputCapture() {
    g_capture_active.store(false);
    g_capture_axis.store(false);
    g_captured_code.store(-1);
}

int32_t ConsumeInputCapture() {
    return g_captured_code.exchange(-1);
}

std::vector<int32_t> GetPressedButtons() {
    std::vector<int32_t> out;
    std::lock_guard<std::mutex> lock(g_map_mutex);
    const auto push_unique = [&out](int32_t key) {
        if (std::find(out.begin(), out.end(), key) == out.end()) {
            out.push_back(key);
        }
    };
    for (const int32_t code : g_held_codes) {
        const auto it = g_map.buttons.find(code);
        if (it == g_map.buttons.end()) {
            continue;
        }
        for (const int32_t native_key : it->second) {
            push_unique(native_key);
        }
    }
    for (int i = 0; i < 2; i++) {
        if (g_dpad_axis_dirs[i] == 0) {
            continue;
        }
        namespace NB = Settings::NativeButton;
        push_unique(i == 0 ? (g_dpad_axis_dirs[i] < 0 ? NB::Up : NB::Down)
                           : (g_dpad_axis_dirs[i] < 0 ? NB::Left : NB::Right));
    }
    return out;
}

std::vector<float> GetAnalogState() {
    std::lock_guard<std::mutex> lock(g_map_mutex);
    return {g_circle_x, g_circle_y, g_cstick_x, g_cstick_y};
}

std::string GetTestStateJson(uint32_t since_seq) {
    std::lock_guard<std::mutex> lock(g_test_mutex);
    nlohmann::json json;
    json["online"] = g_device_seen.load();
    json["name"] = g_device_name;
    json["last"] = g_test.last_code;
    json["pressed"] = g_test.pressed;
    json["axes"] = {g_test.lx, g_test.ly, g_test.rx,
                    g_test.ry, g_test.hat_x, g_test.hat_y};
    json["triggers"] = {g_test.lt, g_test.rt};
    json["now"] = NowMs();
    nlohmann::json events = nlohmann::json::array();
    for (const TestEvent& e : g_test.events) {
        if (e.seq > since_seq) {
            events.push_back({e.seq, e.code, e.down ? 1 : 0, e.time_ms});
        }
    }
    json["events"] = std::move(events);
    return json.dump();
}

void ResetTestState() {
    std::lock_guard<std::mutex> lock(g_test_mutex);
    g_test.events.clear();
    g_test.last_code = -1;
}

bool Initialize() {
    if (g_initialized.exchange(true)) {
        return true;
    }

    if (OH_GameDevice_RegisterDeviceMonitor(OnDeviceChanged) != GAME_CONTROLLER_SUCCESS) {
        g_initialized.store(false);
        OH_LOG_Print(LOG_APP, LOG_WARN, kLogDomain, kLogTag,
                     "Failed to register game controller device monitor");
        return false;
    }

    OH_GamePad_ButtonA_RegisterButtonInputMonitor(OnButtonA);
    OH_GamePad_ButtonB_RegisterButtonInputMonitor(OnButtonB);
    OH_GamePad_ButtonC_RegisterButtonInputMonitor(OnButtonC);
    OH_GamePad_ButtonX_RegisterButtonInputMonitor(OnButtonX);
    OH_GamePad_ButtonY_RegisterButtonInputMonitor(OnButtonY);
    OH_GamePad_LeftShoulder_RegisterButtonInputMonitor(OnLeftShoulder);
    OH_GamePad_RightShoulder_RegisterButtonInputMonitor(OnRightShoulder);
    OH_GamePad_LeftTrigger_RegisterButtonInputMonitor(OnLeftTriggerButton);
    OH_GamePad_RightTrigger_RegisterButtonInputMonitor(OnRightTriggerButton);
    OH_GamePad_ButtonHome_RegisterButtonInputMonitor(OnButtonHome);
    OH_GamePad_ButtonMenu_RegisterButtonInputMonitor(OnButtonMenu);
    OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor(OnDpadUp);
    OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor(OnDpadDown);
    OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor(OnDpadLeft);
    OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor(OnDpadRight);
    OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor(OnLeftThumbstickButton);
    OH_GamePad_RightThumbstick_RegisterButtonInputMonitor(OnRightThumbstickButton);
    OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor(OnLeftThumbstickAxis);
    OH_GamePad_RightThumbstick_RegisterAxisInputMonitor(OnRightThumbstickAxis);
    OH_GamePad_Dpad_RegisterAxisInputMonitor(OnDpadAxis);
    OH_GamePad_LeftTrigger_RegisterAxisInputMonitor(OnLeftTriggerAxis);
    OH_GamePad_RightTrigger_RegisterAxisInputMonitor(OnRightTriggerAxis);
    RefreshConnectedDevice();

    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, "Game Controller Kit initialized");
    return true;
}

void Shutdown() {
    if (!g_initialized.exchange(false)) {
        return;
    }

    OH_GameDevice_UnregisterDeviceMonitor();
    OH_GamePad_ButtonA_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonB_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonC_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonX_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonY_UnregisterButtonInputMonitor();
    OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor();
    OH_GamePad_RightShoulder_UnregisterButtonInputMonitor();
    OH_GamePad_LeftTrigger_UnregisterButtonInputMonitor();
    OH_GamePad_RightTrigger_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonHome_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor();
    OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor();
    OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor();
    OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor();
    OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor();
    OH_GamePad_Dpad_UnregisterAxisInputMonitor();
    OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor();
    OH_GamePad_RightTrigger_UnregisterAxisInputMonitor();

    {
        std::lock_guard<std::mutex> lock(g_map_mutex);
        g_circle_x = g_circle_y = g_cstick_x = g_cstick_y = 0.0f;
        g_held_codes.clear();
        g_dpad_axis_dirs[0] = g_dpad_axis_dirs[1] = 0;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, kLogDomain, kLogTag, "Game Controller Kit shut down");
}

} // namespace Azahar::Ohos::Gamepad
