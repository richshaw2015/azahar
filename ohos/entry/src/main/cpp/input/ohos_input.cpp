#include "input/ohos_input.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <chrono>
#include <list>
#include <memory>
#include <mutex>
#include <string>
#include <tuple>
#include <utility>

#include <sensors/oh_sensor.h>

#include "common/logging/log.h"
#include "common/param_package.h"
#include "common/settings.h"
#include "common/vector_math.h"
#include "core/frontend/input.h"

namespace Azahar::Ohos::Input {
namespace {

constexpr const char* kEngineName = "ohos";
constexpr const char* kMotionEngineName = "ohos_motion";
constexpr float kStandardGravity = 9.80665f;
constexpr float kRadToDeg = 57.29577951308232f;

std::mutex g_mutex;
bool g_initialized = false;

class ButtonList;
class AnalogList;

class Button final : public ::Input::ButtonDevice {
public:
    explicit Button(std::shared_ptr<ButtonList> button_list_) : button_list{std::move(button_list_)} {}
    ~Button() override;

    bool GetStatus() const override {
        return pressed.load();
    }

private:
    friend class ButtonList;

    std::shared_ptr<ButtonList> button_list;
    std::atomic_bool pressed{false};
};

struct ButtonBinding {
    int32_t code = 0;
    Button* button = nullptr;
};

class ButtonList {
public:
    void Add(int32_t code, Button* button) {
        std::lock_guard lock{mutex};
        bindings.push_back(ButtonBinding{code, button});
    }

    void Remove(const Button* button) {
        std::lock_guard lock{mutex};
        bindings.remove_if(
            [button](const ButtonBinding& binding) { return binding.button == button; });
    }

    bool Set(int32_t code, bool pressed) {
        std::lock_guard lock{mutex};
        bool found = false;
        for (const ButtonBinding& binding : bindings) {
            if (binding.code == code) {
                binding.button->pressed.store(pressed);
                found = true;
            }
        }
        return found;
    }

    void ReleaseAll() {
        std::lock_guard lock{mutex};
        for (const ButtonBinding& binding : bindings) {
            binding.button->pressed.store(false);
        }
    }

private:
    std::mutex mutex;
    std::list<ButtonBinding> bindings;
};

Button::~Button() {
    button_list->Remove(this);
}

class Analog final : public ::Input::AnalogDevice {
public:
    explicit Analog(std::shared_ptr<AnalogList> analog_list_) : analog_list{std::move(analog_list_)} {}
    ~Analog() override;

    std::tuple<float, float> GetStatus() const override {
        return {x_axis.load(), y_axis.load()};
    }

private:
    friend class AnalogList;

    std::shared_ptr<AnalogList> analog_list;
    std::atomic<float> x_axis{0.0f};
    std::atomic<float> y_axis{0.0f};
};

struct AnalogBinding {
    int32_t code = 0;
    Analog* analog = nullptr;
};

class AnalogList {
public:
    void Add(int32_t code, Analog* analog) {
        std::lock_guard lock{mutex};
        bindings.push_back(AnalogBinding{code, analog});
    }

    void Remove(const Analog* analog) {
        std::lock_guard lock{mutex};
        bindings.remove_if(
            [analog](const AnalogBinding& binding) { return binding.analog == analog; });
    }

    bool Set(int32_t code, float x, float y) {
        std::lock_guard lock{mutex};
        bool found = false;
        for (const AnalogBinding& binding : bindings) {
            if (binding.code == code) {
                binding.analog->x_axis.store(std::clamp(x, -1.0f, 1.0f));
                binding.analog->y_axis.store(std::clamp(y, -1.0f, 1.0f));
                found = true;
            }
        }
        return found;
    }

    void ReleaseAll() {
        std::lock_guard lock{mutex};
        for (const AnalogBinding& binding : bindings) {
            binding.analog->x_axis.store(0.0f);
            binding.analog->y_axis.store(0.0f);
        }
    }

private:
    std::mutex mutex;
    std::list<AnalogBinding> bindings;
};

Analog::~Analog() {
    analog_list->Remove(this);
}

class ButtonFactory final : public ::Input::Factory<::Input::ButtonDevice> {
public:
    ButtonFactory() : buttons{std::make_shared<ButtonList>()} {}

    std::unique_ptr<::Input::ButtonDevice> Create(const Common::ParamPackage& params) override {
        const int32_t code = params.Get("code", 0);
        auto button = std::make_unique<Button>(buttons);
        buttons->Add(code, button.get());
        return button;
    }

    bool Set(int32_t code, bool pressed) {
        return buttons->Set(code, pressed);
    }

    void ReleaseAll() {
        buttons->ReleaseAll();
    }

private:
    std::shared_ptr<ButtonList> buttons;
};

class AnalogFactory final : public ::Input::Factory<::Input::AnalogDevice> {
public:
    AnalogFactory() : analogs{std::make_shared<AnalogList>()} {}

    std::unique_ptr<::Input::AnalogDevice> Create(const Common::ParamPackage& params) override {
        const int32_t code = params.Get("code", 0);
        auto analog = std::make_unique<Analog>(analogs);
        analogs->Add(code, analog.get());
        return analog;
    }

    bool Set(int32_t code, float x, float y) {
        return analogs->Set(code, x, y);
    }

    void ReleaseAll() {
        analogs->ReleaseAll();
    }

private:
    std::shared_ptr<AnalogList> analogs;
};

std::shared_ptr<ButtonFactory> g_button_factory;
std::shared_ptr<AnalogFactory> g_analog_factory;

std::mutex g_motion_mutex;
Common::Vec3<float> g_acceleration {};
Common::Vec3<float> g_rotation {};
int32_t g_screen_rotation = 0;
int32_t g_motion_device_count = 0;
bool g_accelerometer_subscribed = false;
bool g_gyroscope_subscribed = false;
Sensor_Subscriber* g_sensor_subscriber = nullptr;
Sensor_SubscriptionAttribute* g_sensor_attribute = nullptr;
Sensor_SubscriptionId* g_accelerometer_id = nullptr;
Sensor_SubscriptionId* g_gyroscope_id = nullptr;

std::string GenerateButtonParam(int32_t code) {
    Common::ParamPackage params{
        {"engine", kEngineName},
        {"code", std::to_string(code)},
    };
    return params.Serialize();
}

std::string GenerateAnalogParam(int32_t code) {
    Common::ParamPackage params{
        {"engine", kEngineName},
        {"code", std::to_string(code)},
    };
    return params.Serialize();
}

std::string GenerateMotionParam(int32_t update_period_ms) {
    Common::ParamPackage params{
        {"engine", kMotionEngineName},
        {"update_period", std::to_string(update_period_ms)},
    };
    return params.Serialize();
}

int32_t NormalizeAnalogCode(int32_t analog) {
    if (analog == static_cast<int32_t>(Settings::NativeAnalog::CirclePad)) {
        return kCirclePadAnalog;
    }
    if (analog == static_cast<int32_t>(Settings::NativeAnalog::CStick)) {
        return kCStickAnalog;
    }
    return analog;
}

Common::Vec3<float> TransformAxes(const Common::Vec3<float>& in) {
    Common::Vec3<float> out;
    out.y = in.z;

    switch (std::clamp(g_screen_rotation, 0, 3)) {
    case 0:
        out.x = -in.x;
        out.z = in.y;
        break;
    case 1:
        out.x = in.y;
        out.z = in.x;
        break;
    case 2:
        out.x = in.x;
        out.z = -in.y;
        break;
    case 3:
        out.x = -in.y;
        out.z = -in.x;
        break;
    default:
        break;
    }

    return out;
}

void SensorDataCallback(Sensor_Event* event) {
    if (!event) {
        return;
    }

    Sensor_Type sensor_type {};
    if (OH_SensorEvent_GetType(event, &sensor_type) != SENSOR_SUCCESS) {
        return;
    }

    float* data = nullptr;
    uint32_t length = 0;
    if (OH_SensorEvent_GetData(event, &data, &length) != SENSOR_SUCCESS || !data || length < 3) {
        return;
    }

    std::lock_guard lock{g_motion_mutex};
    const Common::Vec3<float> raw = Common::MakeVec(data[0], data[1], data[2]);
    if (sensor_type == SENSOR_TYPE_ACCELEROMETER) {
        g_acceleration = TransformAxes(raw) / -kStandardGravity;
    } else if (sensor_type == SENSOR_TYPE_GYROSCOPE) {
        g_rotation = TransformAxes(raw) * kRadToDeg;
    }
}

bool SubscribeSensor(Sensor_Type sensor_type, Sensor_SubscriptionId*& id_out, bool& subscribed_out) {
    Sensor_SubscriptionId* id = OH_Sensor_CreateSubscriptionId();
    if (!id) {
        LOG_ERROR(Input, "OHOS sensor subscription id creation failed for type {}", sensor_type);
        return false;
    }

    if (OH_SensorSubscriptionId_SetType(id, sensor_type) != SENSOR_SUCCESS) {
        LOG_ERROR(Input, "OHOS sensor subscription id setup failed for type {}", sensor_type);
        OH_Sensor_DestroySubscriptionId(id);
        return false;
    }

    const Sensor_Result result = OH_Sensor_Subscribe(id, g_sensor_attribute, g_sensor_subscriber);
    if (result != SENSOR_SUCCESS) {
        LOG_WARNING(Input, "OHOS sensor subscribe failed for type {}: {}", sensor_type, result);
        OH_Sensor_DestroySubscriptionId(id);
        return false;
    }

    id_out = id;
    subscribed_out = true;
    return true;
}

void DestroySensorId(Sensor_SubscriptionId*& id) {
    if (id) {
        OH_Sensor_DestroySubscriptionId(id);
        id = nullptr;
    }
}

void StopMotionSensorsLocked() {
    if (g_accelerometer_subscribed && g_accelerometer_id) {
        OH_Sensor_Unsubscribe(g_accelerometer_id, g_sensor_subscriber);
    }
    if (g_gyroscope_subscribed && g_gyroscope_id) {
        OH_Sensor_Unsubscribe(g_gyroscope_id, g_sensor_subscriber);
    }

    g_accelerometer_subscribed = false;
    g_gyroscope_subscribed = false;
    DestroySensorId(g_accelerometer_id);
    DestroySensorId(g_gyroscope_id);

    if (g_sensor_attribute) {
        OH_Sensor_DestroySubscriptionAttribute(g_sensor_attribute);
        g_sensor_attribute = nullptr;
    }
    if (g_sensor_subscriber) {
        OH_Sensor_DestroySubscriber(g_sensor_subscriber);
        g_sensor_subscriber = nullptr;
    }

    g_acceleration = {};
    g_rotation = {};
}

bool StartMotionSensors(int32_t update_period_ms) {
    std::lock_guard lock{g_motion_mutex};

    if (g_accelerometer_subscribed || g_gyroscope_subscribed) {
        ++g_motion_device_count;
        return true;
    }

    g_sensor_subscriber = OH_Sensor_CreateSubscriber();
    g_sensor_attribute = OH_Sensor_CreateSubscriptionAttribute();
    if (!g_sensor_subscriber || !g_sensor_attribute) {
        LOG_ERROR(Input, "OHOS sensor subscriber setup failed");
        StopMotionSensorsLocked();
        return false;
    }

    const int64_t sampling_interval_ns =
        static_cast<int64_t>(std::max(update_period_ms, 1)) * 1000LL * 1000LL;
    if (OH_SensorSubscriber_SetCallback(g_sensor_subscriber, SensorDataCallback) != SENSOR_SUCCESS ||
        OH_SensorSubscriptionAttribute_SetSamplingInterval(g_sensor_attribute,
                                                           sampling_interval_ns) != SENSOR_SUCCESS) {
        LOG_ERROR(Input, "OHOS sensor callback or sampling interval setup failed");
        StopMotionSensorsLocked();
        return false;
    }

    SubscribeSensor(SENSOR_TYPE_ACCELEROMETER, g_accelerometer_id, g_accelerometer_subscribed);
    SubscribeSensor(SENSOR_TYPE_GYROSCOPE, g_gyroscope_id, g_gyroscope_subscribed);
    if (!g_accelerometer_subscribed && !g_gyroscope_subscribed) {
        StopMotionSensorsLocked();
        return false;
    }

    ++g_motion_device_count;
    LOG_INFO(Input, "OHOS motion sensors enabled: accelerometer={}, gyroscope={}",
             g_accelerometer_subscribed, g_gyroscope_subscribed);
    return true;
}

void StopMotionSensors() {
    std::lock_guard lock{g_motion_mutex};
    if (g_motion_device_count > 0) {
        --g_motion_device_count;
    }
    if (g_motion_device_count == 0) {
        StopMotionSensorsLocked();
    }
}

class Motion final : public ::Input::MotionDevice {
public:
    explicit Motion(int32_t update_period_ms) : active{StartMotionSensors(update_period_ms)} {}

    ~Motion() override {
        if (active) {
            StopMotionSensors();
        }
    }

    std::tuple<Common::Vec3<float>, Common::Vec3<float>> GetStatus() const override {
        std::lock_guard lock{g_motion_mutex};
        return {g_acceleration, g_rotation};
    }

private:
    bool active = false;
};

class MotionFactory final : public ::Input::Factory<::Input::MotionDevice> {
public:
    std::unique_ptr<::Input::MotionDevice> Create(const Common::ParamPackage& params) override {
        const int32_t update_period_ms = params.Get("update_period", 4);
        return std::make_unique<Motion>(update_period_ms);
    }
};

std::shared_ptr<MotionFactory> g_motion_factory;

} // namespace

void EnsureInitialized() {
    std::lock_guard lock{g_mutex};
    if (g_initialized) {
        return;
    }

    g_button_factory = std::make_shared<ButtonFactory>();
    g_analog_factory = std::make_shared<AnalogFactory>();
    g_motion_factory = std::make_shared<MotionFactory>();
    ::Input::RegisterFactory<::Input::ButtonDevice>(kEngineName, g_button_factory);
    ::Input::RegisterFactory<::Input::AnalogDevice>(kEngineName, g_analog_factory);
    ::Input::RegisterFactory<::Input::MotionDevice>(kMotionEngineName, g_motion_factory);
    g_initialized = true;
}

void Shutdown() {
    std::lock_guard lock{g_mutex};
    if (!g_initialized) {
        return;
    }

    if (g_button_factory) {
        g_button_factory->ReleaseAll();
    }
    if (g_analog_factory) {
        g_analog_factory->ReleaseAll();
    }
    {
        std::lock_guard motion_lock{g_motion_mutex};
        g_motion_device_count = 0;
        StopMotionSensorsLocked();
    }
    ::Input::UnregisterFactory<::Input::ButtonDevice>(kEngineName);
    ::Input::UnregisterFactory<::Input::AnalogDevice>(kEngineName);
    ::Input::UnregisterFactory<::Input::MotionDevice>(kMotionEngineName);
    g_button_factory.reset();
    g_analog_factory.reset();
    g_motion_factory.reset();
    g_initialized = false;
}

void ApplyDefaultProfile() {
    EnsureInitialized();

    for (int32_t i = 0; i < Settings::NativeButton::NumButtons; ++i) {
        Settings::values.current_input_profile.buttons[i] = GenerateButtonParam(i);
    }

    Settings::values.current_input_profile.analogs[Settings::NativeAnalog::CirclePad] =
        GenerateAnalogParam(kCirclePadAnalog);
    Settings::values.current_input_profile.analogs[Settings::NativeAnalog::CStick] =
        GenerateAnalogParam(kCStickAnalog);
    Settings::values.current_input_profile.motion_device = GenerateMotionParam(4);
    Settings::values.current_input_profile.touch_device = "engine:emu_window";
    Settings::values.current_input_profile.controller_touch_device = {};
    Settings::values.current_input_profile.use_touchpad = false;
    Settings::values.current_input_profile.use_touch_from_button = false;
    Settings::values.current_input_profile.touch_from_button_map_index = 0;
    Settings::values.current_input_profile.udp_pad_index = 0;
}

bool SetButtonState(int32_t native_button, bool pressed) {
    if (native_button < 0 || native_button >= Settings::NativeButton::NumButtons) {
        return false;
    }

    EnsureInitialized();
    std::shared_ptr<ButtonFactory> button_factory;
    {
        std::lock_guard lock{g_mutex};
        button_factory = g_button_factory;
    }
    return button_factory ? button_factory->Set(native_button, pressed) : false;
}

bool SetAnalogState(int32_t analog, float x, float y) {
    const int32_t code = NormalizeAnalogCode(analog);
    if (code != kCirclePadAnalog && code != kCStickAnalog) {
        return false;
    }

    EnsureInitialized();
    std::shared_ptr<AnalogFactory> analog_factory;
    {
        std::lock_guard lock{g_mutex};
        analog_factory = g_analog_factory;
    }
    return analog_factory ? analog_factory->Set(code, x, y) : false;
}

bool SetScreenRotation(int32_t rotation) {
    if (rotation < 0 || rotation > 3) {
        return false;
    }

    std::lock_guard lock{g_motion_mutex};
    g_screen_rotation = rotation;
    return true;
}

void ReleaseAll() {
    std::shared_ptr<ButtonFactory> button_factory;
    std::shared_ptr<AnalogFactory> analog_factory;
    {
        std::lock_guard lock{g_mutex};
        button_factory = g_button_factory;
        analog_factory = g_analog_factory;
    }

    if (button_factory) {
        button_factory->ReleaseAll();
    }
    if (analog_factory) {
        analog_factory->ReleaseAll();
    }
}

} // namespace Azahar::Ohos::Input
