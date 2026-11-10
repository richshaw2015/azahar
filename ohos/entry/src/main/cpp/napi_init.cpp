#include "core/azahar_core_bridge.h"
#include "core/azahar_core_runtime.h"
#include "core/savestate.h"
#include "graphics/ohos_graphics_info.h"
#include "graphics/ohos_xcomponent_bridge.h"
#if AZAHAR_OHOS_CORE_AVAILABLE
#include "camera/ohos_camera.h"
#include "camera/ohos_still_image_camera.h"
#include "input/ohos_gamepad.h"
#include "input/ohos_input.h"
#endif

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <napi/native_api.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <atomic>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "Azahar_OHOS"
#define LOG_DOMAIN 0x3203

#define AZ_LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define AZ_LOGW(fmt, ...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define AZ_LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

#ifdef AZAHAR_OHOS_TESTS
std::string AzaharOhosRunNativeTests(const std::string& filter);
std::string AzaharOhosAsmCrashProbe();
#endif

namespace {

using Azahar::Ohos::AppInfo;
using Azahar::Ohos::CheatInfo;
using Azahar::Ohos::ConfigValue;
using Azahar::Ohos::CoreBackend;
using Azahar::Ohos::CoreBackendName;
using Azahar::Ohos::CoreBridge;
using Azahar::Ohos::GameMetadata;
using Azahar::Ohos::GraphicsInfo;
using Azahar::Ohos::JitPolicy;
using Azahar::Ohos::LoadResult;
using Azahar::Ohos::MultiplayerRoomInfo;
using Azahar::Ohos::RuntimeInfo;
using Azahar::Ohos::RuntimeStateName;
using Azahar::Ohos::RomFsDumpResult;
using Azahar::Ohos::MovieStatus;
using Azahar::Ohos::MovieMetadata;
using Azahar::Ohos::SystemFilesStatus;
using Azahar::Ohos::SystemProfile;
using Azahar::Ohos::TitleContentStatus;

napi_ref g_saved_exports_ref = nullptr;

bool GetString(napi_env env, napi_value value, std::string& out) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_string) {
        return false;
    }

    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }

    std::vector<char> buffer(length + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &copied) != napi_ok) {
        return false;
    }
    out.assign(buffer.data(), copied);
    return true;
}

bool GetBool(napi_env env, napi_value value, bool& out) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_boolean) {
        return false;
    }
    return napi_get_value_bool(env, value, &out) == napi_ok;
}

bool GetDouble(napi_env env, napi_value value, double& out) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number) {
        return false;
    }
    return napi_get_value_double(env, value, &out) == napi_ok;
}

bool GetInt32(napi_env env, napi_value value, int32_t& out);

bool GetNamedValue(napi_env env, napi_value object, const char* name, napi_value& out) {
    bool has_property = false;
    if (napi_has_named_property(env, object, name, &has_property) != napi_ok || !has_property) {
        return false;
    }
    return napi_get_named_property(env, object, name, &out) == napi_ok;
}

bool GetNamedString(napi_env env, napi_value object, const char* name, std::string& out) {
    napi_value value;
    return GetNamedValue(env, object, name, value) && GetString(env, value, out);
}

bool GetNamedBool(napi_env env, napi_value object, const char* name, bool& out) {
    napi_value value;
    return GetNamedValue(env, object, name, value) && GetBool(env, value, out);
}

bool GetNamedInt32(napi_env env, napi_value object, const char* name, int32_t& out) {
    napi_value value;
    return GetNamedValue(env, object, name, value) && GetInt32(env, value, out);
}

bool GetInt32(napi_env env, napi_value value, int32_t& out) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok || type != napi_number) {
        return false;
    }
    return napi_get_value_int32(env, value, &out) == napi_ok;
}

napi_value MakeBool(napi_env env, bool value) {
    napi_value result;
    napi_get_boolean(env, value, &result);
    return result;
}

napi_value MakeNumber(napi_env env, double value) {
    napi_value result;
    napi_create_double(env, value, &result);
    return result;
}

napi_value MakeString(napi_env env, const std::string& value) {
    napi_value result;
    napi_create_string_utf8(env, value.c_str(), value.length(), &result);
    return result;
}

napi_value MakeUndefined(napi_env env) {
    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

void SetNamed(napi_env env, napi_value object, const char* name, napi_value value) {
    napi_set_named_property(env, object, name, value);
}

void SetArrayBuffer(napi_env env, napi_value object, const char* name, const std::vector<uint8_t>& bytes) {
    if (bytes.empty()) {
        return;
    }

    void* data = nullptr;
    napi_value buffer;
    if (napi_create_arraybuffer(env, bytes.size(), &data, &buffer) != napi_ok || data == nullptr) {
        return;
    }
    std::memcpy(data, bytes.data(), bytes.size());
    SetNamed(env, object, name, buffer);
}

napi_value ConfigValueToNapi(napi_env env, const ConfigValue& value) {
    if (std::holds_alternative<bool>(value)) {
        return MakeBool(env, std::get<bool>(value));
    }
    if (std::holds_alternative<double>(value)) {
        return MakeNumber(env, std::get<double>(value));
    }
    return MakeString(env, std::get<std::string>(value));
}

bool NapiToConfigValue(napi_env env, napi_value value, ConfigValue& out) {
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok) {
        return false;
    }

    switch (type) {
    case napi_boolean: {
        bool bool_value = false;
        if (!GetBool(env, value, bool_value)) {
            return false;
        }
        out = bool_value;
        return true;
    }
    case napi_number: {
        double number_value = 0.0;
        if (!GetDouble(env, value, number_value)) {
            return false;
        }
        out = number_value;
        return true;
    }
    case napi_string: {
        std::string string_value;
        if (!GetString(env, value, string_value)) {
            return false;
        }
        out = std::move(string_value);
        return true;
    }
    default:
        return false;
    }
}

napi_value RuntimeInfoToNapi(napi_env env, const RuntimeInfo& info) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "initialized", MakeBool(env, info.initialized));
    SetNamed(env, result, "state", MakeString(env, RuntimeStateName(info.state)));
    SetNamed(env, result, "loadedPath", MakeString(env, info.loaded_path));
    SetNamed(env, result, "deviceType", MakeString(env, info.device_type));
    SetNamed(env, result, "jitSupported", MakeBool(env, info.jit.supported));
    SetNamed(env, result, "jitAvailable", MakeBool(env, info.jit.available));
    SetNamed(env, result, "jitReason", MakeString(env, info.jit.reason));
    SetNamed(env, result, "surfaceReady", MakeBool(env, info.surface.ready));
    SetNamed(env, result, "coreLinked", MakeBool(env, info.backend == CoreBackend::AzaharCore));
    SetNamed(env, result, "coreBackend", MakeString(env, CoreBackendName(info.backend)));
    SetNamed(env, result, "backendStatus", MakeString(env, info.backend_status));
    return result;
}

napi_value GraphicsInfoToNapi(napi_env env, const GraphicsInfo& info) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "vulkanVersion", MakeString(env, info.vulkan_version));
    SetNamed(env, result, "glesVersion", MakeString(env, info.gles_version));
    SetNamed(env, result, "gpuName", MakeString(env, info.gpu_name));
    return result;
}

napi_value AppInfoToNapi(napi_env env, const AppInfo& info) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "path", MakeString(env, info.path));
    SetNamed(env, result, "fileName", MakeString(env, info.file_name));
    SetNamed(env, result, "extension", MakeString(env, info.extension));
    SetNamed(env, result, "supported", MakeBool(env, info.supported));
    return result;
}

napi_value GameMetadataToNapi(napi_env env, const GameMetadata& metadata) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "path", MakeString(env, metadata.path));
    SetNamed(env, result, "titleId", MakeString(env, metadata.title_id));
    SetNamed(env, result, "shortTitle", MakeString(env, metadata.short_title));
    SetNamed(env, result, "longTitle", MakeString(env, metadata.long_title));
    SetNamed(env, result, "publisher", MakeString(env, metadata.publisher));
    SetNamed(env, result, "regions", MakeString(env, metadata.regions));
    SetNamed(env, result, "productCode", MakeString(env, metadata.product_code));
    SetNamed(env, result, "extdataId", MakeString(env, metadata.extdata_id));
    SetNamed(env, result, "fileType", MakeString(env, metadata.file_type));
    SetNamed(env, result, "iconStatus", MakeString(env, metadata.icon_status));
    SetNamed(env, result, "valid", MakeBool(env, metadata.valid));
    SetNamed(env, result, "encrypted", MakeBool(env, metadata.encrypted));
    SetNamed(env, result, "insertable", MakeBool(env, metadata.insertable));
    SetNamed(env, result, "systemTitle", MakeBool(env, metadata.system_title));
    SetNamed(env, result, "visible", MakeBool(env, metadata.visible));
    SetNamed(env, result, "hasIcon", MakeBool(env, metadata.has_icon));
    SetNamed(env, result, "iconWidth", MakeNumber(env, metadata.icon_width));
    SetNamed(env, result, "iconHeight", MakeNumber(env, metadata.icon_height));
    SetArrayBuffer(env, result, "iconRgb565", metadata.icon_rgb565);
    SetArrayBuffer(env, result, "icon", metadata.icon_rgba);
    return result;
}

napi_value CheatInfoToNapi(napi_env env, const CheatInfo& cheat) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "index", MakeNumber(env, cheat.index));
    SetNamed(env, result, "name", MakeString(env, cheat.name));
    SetNamed(env, result, "notes", MakeString(env, cheat.notes));
    SetNamed(env, result, "code", MakeString(env, cheat.code));
    SetNamed(env, result, "type", MakeString(env, cheat.type));
    SetNamed(env, result, "enabled", MakeBool(env, cheat.enabled));
    return result;
}

napi_value MultiplayerRoomInfoToNapi(napi_env env, const MultiplayerRoomInfo& room) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "id", MakeString(env, room.id));
    SetNamed(env, result, "name", MakeString(env, room.name));
    SetNamed(env, result, "description", MakeString(env, room.description));
    SetNamed(env, result, "owner", MakeString(env, room.owner));
    SetNamed(env, result, "address", MakeString(env, room.address));
    SetNamed(env, result, "port", MakeNumber(env, room.port));
    SetNamed(env, result, "maxPlayers", MakeNumber(env, room.max_players));
    SetNamed(env, result, "memberCount", MakeNumber(env, room.member_count));
    SetNamed(env, result, "netVersion", MakeNumber(env, room.net_version));
    SetNamed(env, result, "hasPassword", MakeBool(env, room.has_password));
    SetNamed(env, result, "preferredGame", MakeString(env, room.preferred_game));
    SetNamed(env, result, "preferredGameId", MakeString(env, room.preferred_game_id));
    return result;
}

napi_value SystemProfileToNapi(napi_env env, const SystemProfile& profile) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "available", MakeBool(env, profile.available));
    SetNamed(env, result, "username", MakeString(env, profile.username));
    SetNamed(env, result, "birthMonth", MakeNumber(env, profile.birth_month));
    SetNamed(env, result, "birthDay", MakeNumber(env, profile.birth_day));
    SetNamed(env, result, "language", MakeNumber(env, profile.language));
    SetNamed(env, result, "soundOutputMode", MakeNumber(env, profile.sound_output_mode));
    SetNamed(env, result, "countryCode", MakeNumber(env, profile.country_code));
    SetNamed(env, result, "systemSetupNeeded", MakeBool(env, profile.system_setup_needed));
    SetNamed(env, result, "playCoins", MakeNumber(env, profile.play_coins));
    SetNamed(env, result, "macAddress", MakeString(env, profile.mac_address));
    SetNamed(env, result, "consoleId", MakeNumber(env, static_cast<double>(profile.console_id)));
    {
        char id_buf[24];
        std::snprintf(id_buf, sizeof(id_buf), "0x%016llX",
                      static_cast<unsigned long long>(profile.console_id));
        SetNamed(env, result, "consoleIdText", MakeString(env, id_buf));
    }
    return result;
}

napi_value SystemFilesStatusToNapi(napi_env env, const SystemFilesStatus& status) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "old3dsInstalled", MakeBool(env, status.old3ds_installed));
    SetNamed(env, result, "new3dsInstalled", MakeBool(env, status.new3ds_installed));
    return result;
}

napi_value TitleContentStatusToNapi(napi_env env, const TitleContentStatus& status) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "applicationInstalled", MakeBool(env, status.application_installed));
    SetNamed(env, result, "updateInstalled", MakeBool(env, status.update_installed));
    SetNamed(env, result, "dlcInstalled", MakeBool(env, status.dlc_installed));
    SetNamed(env, result, "applicationPath", MakeString(env, status.application_path));
    SetNamed(env, result, "updatePath", MakeString(env, status.update_path));
    SetNamed(env, result, "dlcPath", MakeString(env, status.dlc_path));
    return result;
}

napi_value RomFsDumpResultToNapi(napi_env env, const RomFsDumpResult& dump_result) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "success", MakeBool(env, dump_result.success));
    SetNamed(env, result, "baseStatus", MakeNumber(env, dump_result.base_status));
    SetNamed(env, result, "updateStatus", MakeNumber(env, dump_result.update_status));
    SetNamed(env, result, "basePath", MakeString(env, dump_result.base_path));
    SetNamed(env, result, "updatePath", MakeString(env, dump_result.update_path));
    return result;
}

napi_value MovieStatusToNapi(napi_env env, const MovieStatus& status) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "mode", MakeString(env, status.mode));
    SetNamed(env, result, "currentInput", MakeNumber(env, static_cast<double>(status.current_input)));
    SetNamed(env, result, "totalInput", MakeNumber(env, static_cast<double>(status.total_input)));
    return result;
}

napi_value MovieMetadataToNapi(napi_env env, const MovieMetadata& metadata) {
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "valid", MakeBool(env, metadata.valid));
    SetNamed(env, result, "validationResult", MakeNumber(env, metadata.validation_result));
    SetNamed(env, result, "titleId", MakeString(env, metadata.title_id));
    SetNamed(env, result, "author", MakeString(env, metadata.author));
    SetNamed(env, result, "rerecordCount", MakeNumber(env, metadata.rerecord_count));
    SetNamed(env, result, "inputCount", MakeNumber(env, static_cast<double>(metadata.input_count)));
    return result;
}

napi_value InitEmulator(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string files_dir;
    std::string cache_dir;
    std::string user_dir;
    if (argc < 3 || !GetString(env, args[0], files_dir) || !GetString(env, args[1], cache_dir) ||
        !GetString(env, args[2], user_dir) || user_dir.empty()) {
        AZ_LOGE("initEmulator requires filesDir, cacheDir and userDir");
        return MakeBool(env, false);
    }

    std::string device_type = "phone";
    bool tablet_jit_user_enabled = false;
    if (argc >= 4) {
        GetString(env, args[3], device_type);
    }
    if (argc >= 5) {
        GetBool(env, args[4], tablet_jit_user_enabled);
    }

    const bool initialized = CoreBridge::Get().Initialize(
        std::move(files_dir), std::move(cache_dir), std::move(user_dir), device_type,
        tablet_jit_user_enabled);
    const JitPolicy jit = CoreBridge::Get().EvaluateJitPolicy(device_type, tablet_jit_user_enabled);
    AZ_LOGI("Azahar OHOS runtime initialized. device=%{public}s, jit=%{public}d",
            device_type.c_str(), jit.available ? 1 : 0);
    return MakeBool(env, initialized);
}

napi_value ShutdownEmulator(napi_env env, napi_callback_info info) {
    Azahar::Ohos::ResetXComponentBridge();
    return MakeBool(env, CoreBridge::Get().Shutdown());
}

napi_value LoadApplication(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc < 1 || !GetString(env, args[0], path)) {
        return MakeNumber(env, static_cast<int32_t>(LoadResult::EmptyPath));
    }

    const LoadResult result = CoreBridge::Get().LoadApplication(path);
    if (result == LoadResult::Success) {
        AZ_LOGI("Application loaded into OHOS runtime bridge: %{public}s", path.c_str());
    }
    return MakeNumber(env, static_cast<int32_t>(result));
}

napi_value StartEmulation(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().StartEmulation());
}

napi_value PauseEmulation(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().PauseEmulation());
}

napi_value ResumeEmulation(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().ResumeEmulation());
}

napi_value DoFrame(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().DoFrame());
}

napi_value StopEmulation(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().StopEmulation());
}

napi_value ResetEmulation(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().ResetEmulation());
}

napi_value IsRunning(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().IsRunning());
}

napi_value IsPaused(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().IsPaused());
}

napi_value ConsumeCameraPermissionRequest(napi_env env, napi_callback_info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    return MakeBool(env, Camera::Ohos::ConsumeCameraPermissionRequest());
#else
    return MakeBool(env, false);
#endif
}

napi_value ConsumeMicPermissionRequest(napi_env env, napi_callback_info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    return MakeBool(env, Azahar::Ohos::ConsumeMicPermissionRequest());
#else
    return MakeBool(env, false);
#endif
}

napi_value ConsumeStillImagePickRequest(napi_env env, napi_callback_info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    return MakeBool(env, Camera::OhosStillImage::ConsumeStillImagePickRequest());
#else
    return MakeBool(env, false);
#endif
}

napi_value ConsumeCoreError(napi_env env, napi_callback_info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    std::string status, details;
    if (Azahar::Ohos::ConsumeCoreError(status, details)) {
        napi_value result;
        napi_create_object(env, &result);
        SetNamed(env, result, "status", MakeString(env, status));
        SetNamed(env, result, "details", MakeString(env, details));
        return result;
    }
#endif
    napi_value result;
    napi_get_null(env, &result);
    return result;
}

napi_value SetStillImagePath(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

#if AZAHAR_OHOS_CORE_AVAILABLE
    std::string path;
    if (argc >= 1 && GetString(env, args[0], path)) {
        Camera::OhosStillImage::SetStillImagePath(path);
        return MakeBool(env, true);
    }
#endif
    return MakeBool(env, false);
}

napi_value StartGamepadInputCapture(napi_env env, napi_callback_info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Azahar::Ohos::Gamepad::StartInputCapture();
    return MakeBool(env, true);
#else
    return MakeBool(env, false);
#endif
}

napi_value StartGamepadAxisCapture(napi_env env, napi_callback_info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Azahar::Ohos::Gamepad::StartAxisInputCapture();
    return MakeBool(env, true);
#else
    return MakeBool(env, false);
#endif
}

napi_value CancelGamepadInputCapture(napi_env env, napi_callback_info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Azahar::Ohos::Gamepad::CancelInputCapture();
    return MakeBool(env, true);
#else
    return MakeBool(env, false);
#endif
}

napi_value ConsumeGamepadInputCapture(napi_env env, napi_callback_info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    return MakeNumber(env, static_cast<double>(Azahar::Ohos::Gamepad::ConsumeInputCapture()));
#else
    return MakeNumber(env, -1.0);
#endif
}

napi_value GetGamepadTestState(napi_env env, napi_callback_info info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    int32_t since = 0;
    if (argc >= 1 && argv[0] != nullptr) {
        GetInt32(env, argv[0], since);
    }
    return MakeString(env, Azahar::Ohos::Gamepad::GetTestStateJson(
                               static_cast<uint32_t>(std::max(since, 0))));
#else
    return MakeString(env, "{}");
#endif
}

napi_value ResetGamepadTestState(napi_env env, napi_callback_info) {
#if AZAHAR_OHOS_CORE_AVAILABLE
    Azahar::Ohos::Gamepad::ResetTestState();
    return MakeBool(env, true);
#else
    return MakeBool(env, false);
#endif
}

// Native-button ids currently held by gamepad input (post-mapping); the in-game
// virtual pad polls this to mirror physical presses on the overlay.
napi_value GetGamepadPressedKeys(napi_env env, napi_callback_info) {
    napi_value array = nullptr;
    napi_create_array(env, &array);
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto held = Azahar::Ohos::Gamepad::GetPressedButtons();
    for (size_t i = 0; i < held.size(); i++) {
        napi_set_element(env, array, static_cast<uint32_t>(i),
                         MakeNumber(env, static_cast<double>(held[i])));
    }
#endif
    return array;
}

// 3DS analog values driven by gamepad input (post deadzone/mapping):
// [circlepad_x, circlepad_y, cstick_x, cstick_y]. Polled by the in-game
// virtual pad to move the on-screen sticks with the physical ones.
napi_value GetGamepadAnalogState(napi_env env, napi_callback_info) {
    napi_value array = nullptr;
    napi_create_array(env, &array);
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto axes = Azahar::Ohos::Gamepad::GetAnalogState();
    for (size_t i = 0; i < axes.size(); i++) {
        napi_set_element(env, array, static_cast<uint32_t>(i),
                         MakeNumber(env, static_cast<double>(axes[i])));
    }
#endif
    return array;
}

napi_value GetCameraDevices(napi_env env, napi_callback_info) {
    napi_value array = nullptr;
    napi_create_array(env, &array);
#if AZAHAR_OHOS_CORE_AVAILABLE
    const auto devices = Camera::Ohos::EnumerateCameraDevices();
    for (size_t i = 0; i < devices.size(); i++) {
        napi_value device = nullptr;
        napi_create_object(env, &device);
        SetNamed(env, device, "id", MakeString(env, devices[i].id));
        SetNamed(env, device, "position", MakeNumber(env, devices[i].position));
        SetNamed(env, device, "type", MakeNumber(env, devices[i].type));
        SetNamed(env, device, "connection", MakeNumber(env, devices[i].connection));
        napi_set_element(env, array, static_cast<uint32_t>(i), device);
    }
#endif
    return array;
}

napi_value SendTouchEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double x = 0.0;
    double y = 0.0;
    int32_t action = 0;
    if (argc < 3 || !GetDouble(env, args[0], x) || !GetDouble(env, args[1], y) ||
        !GetInt32(env, args[2], action)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().SendTouchEvent(x, y, action));
}

napi_value SendKeyEvent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t key = 0;
    bool is_down = false;
    if (argc < 2 || !GetInt32(env, args[0], key) || !GetBool(env, args[1], is_down)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().SendKeyEvent(key, is_down));
}

napi_value SendAnalogEvent(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t analog = 0;
    double x = 0.0;
    double y = 0.0;
    if (argc < 3 || !GetInt32(env, args[0], analog) || !GetDouble(env, args[1], x) ||
        !GetDouble(env, args[2], y)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().SendAnalogEvent(analog, x, y));
}

napi_value SetShellOpen(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool open = true;
    if (argc < 1 || !GetBool(env, args[0], open)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().SetShellOpen(open));
}

napi_value GetShellOpen(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().IsShellOpen());
}

napi_value GetSystemSleepState(napi_env env, napi_callback_info info) {
    napi_value value = nullptr;
    napi_create_int32(env, CoreBridge::Get().GetSystemSleepState(), &value);
    return value;
}

napi_value SetScreenRotation(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t rotation = 0;
    if (argc < 1 || !GetInt32(env, args[0], rotation)) {
        return MakeBool(env, false);
    }
#if AZAHAR_OHOS_CORE_AVAILABLE
    return MakeBool(env, Azahar::Ohos::Input::SetScreenRotation(rotation));
#else
    return MakeBool(env, false);
#endif
}

struct SaveStateWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    int32_t slot = 0;
    bool result = false;
};

// 存档需要驱动模拟线程消费 Save 信号并等 .cst 落盘 + 截图，耗时较长；
// 放到 async work 里执行，UI 线程可以继续渲染"保存中"遮罩动画
napi_value SaveState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value promise = nullptr;
    napi_deferred deferred = nullptr;
    napi_create_promise(env, &deferred, &promise);

    int32_t slot = 0;
    if (argc < 1 || !GetInt32(env, args[0], slot)) {
        napi_resolve_deferred(env, deferred, MakeBool(env, false));
        return promise;
    }

    auto* work_data = new SaveStateWork();
    work_data->slot = slot;
    work_data->deferred = deferred;

    napi_value resource_name = nullptr;
    napi_create_string_utf8(env, "AzaharSaveState", NAPI_AUTO_LENGTH, &resource_name);
    napi_create_async_work(
        env, nullptr, resource_name,
        [](napi_env, void* data) {
            auto* work = static_cast<SaveStateWork*>(data);
            work->result = CoreBridge::Get().SaveState(work->slot);
        },
        [](napi_env env, napi_status, void* data) {
            auto* work = static_cast<SaveStateWork*>(data);
            napi_resolve_deferred(env, work->deferred, MakeBool(env, work->result));
            napi_delete_async_work(env, work->work);
            delete work;
        },
        work_data, &work_data->work);
    napi_queue_async_work(env, work_data->work);
    return promise;
}

napi_value LoadState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t slot = 0;
    if (argc < 1 || !GetInt32(env, args[0], slot)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().LoadState(slot));
}

napi_value GetSaveStateInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 槽位上限可选，默认对齐上游 SaveStateSlotCount（手动槽 1-10 + 快速槽 0）
    int32_t max_slot = static_cast<int32_t>(Core::SaveStateSlotCount);
    if (argc >= 1 && !GetInt32(env, args[0], max_slot)) {
        max_slot = static_cast<int32_t>(Core::SaveStateSlotCount);
    }
    if (max_slot < 0) {
        max_slot = 0;
    }
    const auto savestates = CoreBridge::Get().ListSaveStates(max_slot);
    napi_value array;
    napi_create_array_with_length(env, savestates.size(), &array);

    for (std::size_t i = 0; i < savestates.size(); ++i) {
        napi_value item;
        napi_create_object(env, &item);
        SetNamed(env, item, "slot", MakeNumber(env, savestates[i].slot));
        SetNamed(env, item, "time", MakeNumber(env, static_cast<double>(savestates[i].time)));
        SetNamed(env, item, "status", MakeNumber(env, savestates[i].status));
        SetNamed(env, item, "buildName", MakeString(env, savestates[i].build_name));
        SetNamed(env, item, "fileSize", MakeNumber(env, static_cast<double>(savestates[i].file_size)));
        SetNamed(env, item, "screenshotPath", MakeString(env, savestates[i].screenshot_path));
        SetNamed(env, item, "hasUndo", MakeBool(env, savestates[i].has_undo));
        napi_set_element(env, array, static_cast<uint32_t>(i), item);
    }
    return array;
}

napi_value DeleteState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t slot = 0;
    if (argc < 1 || !GetInt32(env, args[0], slot)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().DeleteSaveState(slot));
}

napi_value HasUndoState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t slot = 0;
    if (argc < 1 || !GetInt32(env, args[0], slot)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().HasUndoSaveState(slot));
}

napi_value UndoState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t slot = 0;
    if (argc < 1 || !GetInt32(env, args[0], slot)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().UndoSaveState(slot));
}

napi_value CaptureScreenshot(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    int32_t resolution_scale = 0;
    if (argc < 1 || !GetString(env, args[0], path)) {
        return MakeBool(env, false);
    }
    if (argc >= 2) {
        GetInt32(env, args[1], resolution_scale);
    }
    return MakeBool(env, CoreBridge::Get().CaptureScreenshot(path, resolution_scale));
}

napi_value InstallCIA(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc < 1 || !GetString(env, args[0], path)) {
        return MakeNumber(env, 2);
    }
    return MakeNumber(env, CoreBridge::Get().InstallCIA(path));
}

napi_value GetInstalledGamePaths(napi_env env, napi_callback_info info) {
    const std::vector<std::string> paths = CoreBridge::Get().GetInstalledGamePaths();
    napi_value array;
    napi_create_array_with_length(env, paths.size(), &array);
    for (std::size_t i = 0; i < paths.size(); ++i) {
        napi_set_element(env, array, static_cast<uint32_t>(i), MakeString(env, paths[i]));
    }
    return array;
}

napi_value GetCheats(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string title_id;
    if (argc < 1 || !GetString(env, args[0], title_id)) {
        napi_value array;
        napi_create_array_with_length(env, 0, &array);
        return array;
    }

    const auto cheats = CoreBridge::Get().ListCheats(title_id);
    napi_value array;
    napi_create_array_with_length(env, cheats.size(), &array);
    for (std::size_t i = 0; i < cheats.size(); ++i) {
        napi_set_element(env, array, static_cast<uint32_t>(i), CheatInfoToNapi(env, cheats[i]));
    }
    return array;
}

napi_value HasGamePerfHacks(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string title_id;
    if (argc < 1 || !GetString(env, args[0], title_id)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().HasGamePerfHacks(title_id));
}

napi_value SetCheatEnabled(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string title_id;
    int32_t index = -1;
    bool enabled = false;
    if (argc < 3 || !GetString(env, args[0], title_id) || !GetInt32(env, args[1], index) ||
        !GetBool(env, args[2], enabled)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().SetCheatEnabled(title_id, index, enabled));
}

napi_value UpsertGatewayCheat(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string title_id;
    int32_t index = -1;
    std::string name;
    std::string notes;
    std::string code;
    bool enabled = false;
    if (argc < 6 || !GetString(env, args[0], title_id) || !GetInt32(env, args[1], index) ||
        !GetString(env, args[2], name) || !GetString(env, args[3], notes) ||
        !GetString(env, args[4], code) || !GetBool(env, args[5], enabled)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().UpsertGatewayCheat(title_id, index, name, notes, code,
                                                              enabled));
}

napi_value RemoveCheat(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string title_id;
    int32_t index = -1;
    if (argc < 2 || !GetString(env, args[0], title_id) || !GetInt32(env, args[1], index)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().RemoveCheat(title_id, index));
}

napi_value ImportCheats(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string title_id;
    std::string contents;
    if (argc < 2 || !GetString(env, args[0], title_id) || !GetString(env, args[1], contents)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().ImportCheats(title_id, contents));
}

napi_value ValidateGatewayCheatCode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string code;
    if (argc < 1 || !GetString(env, args[0], code)) {
        return MakeNumber(env, 1);
    }
    return MakeNumber(env, CoreBridge::Get().ValidateGatewayCheatCode(code));
}

napi_value IsSearchingForAmiibo(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().IsSearchingForAmiibo());
}

napi_value LoadAmiibo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc < 1 || !GetString(env, args[0], path)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().LoadAmiibo(path));
}

napi_value RemoveAmiibo(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().RemoveAmiibo());
}

napi_value MakeAmiiboFile(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2]{};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string id, path;
    if (argc < 2 || !GetString(env, args[0], id) || !GetString(env, args[1], path)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().MakeAmiiboFile(id, path));
}

static napi_value ZipPassOneString(napi_env env, napi_callback_info info,
                                   int (CoreBridge::*fn)(const std::string&)) {
    size_t argc = 1;
    napi_value args[1]{};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc < 1 || !GetString(env, args[0], path)) {
        return MakeNumber(env, -1);
    }
    return MakeNumber(env, (CoreBridge::Get().*fn)(path));
}

napi_value ZipPassExport(napi_env env, napi_callback_info info) {
    return ZipPassOneString(env, info, &CoreBridge::ZipPassExport);
}

napi_value ZipPassImport(napi_env env, napi_callback_info info) {
    return ZipPassOneString(env, info, &CoreBridge::ZipPassImport);
}

napi_value ZipPassImportQueued(napi_env env, napi_callback_info info) {
    return MakeNumber(env, CoreBridge::Get().ZipPassImportQueued());
}

napi_value ZipPassClearStreetPass(napi_env env, napi_callback_info info) {
    return MakeNumber(env, CoreBridge::Get().ZipPassClearStreetPass());
}

napi_value MultiplayerJoinRoom(napi_env env, napi_callback_info info) {
    napi_value args[4];
    size_t argc = 4;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string address, username, password;
    int32_t port = 0;
    GetString(env, args[0], address);
    GetInt32(env, args[1], port);
    GetString(env, args[2], username);
    GetString(env, args[3], password);
    return MakeNumber(env,
                      CoreBridge::Get().MultiplayerJoinRoom(address, port, username, password));
}

napi_value MultiplayerCreateRoom(napi_env env, napi_callback_info info) {
    napi_value args[8];
    size_t argc = 8;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string address, username, game_name, password, room_name;
    int32_t port = 0, max_players = 0;
    double game_id = 0;
    GetString(env, args[0], address);
    GetInt32(env, args[1], port);
    GetString(env, args[2], username);
    GetString(env, args[3], game_name);
    GetDouble(env, args[4], game_id);
    GetString(env, args[5], password);
    GetString(env, args[6], room_name);
    GetInt32(env, args[7], max_players);
    return MakeNumber(env, CoreBridge::Get().MultiplayerCreateRoom(
                             address, port, username, game_name, static_cast<int64_t>(game_id),
                             password, room_name, max_players));
}

napi_value MultiplayerLeaveRoom(napi_env env, napi_callback_info info) {
    CoreBridge::Get().MultiplayerLeaveRoom();
    return MakeUndefined(env);
}

napi_value GetMultiplayerSessionInfo(napi_env env, napi_callback_info info) {
    const auto session = CoreBridge::Get().GetMultiplayerSessionInfo();
    napi_value result;
    napi_create_object(env, &result);
    SetNamed(env, result, "initialized", MakeBool(env, session.initialized));
    SetNamed(env, result, "joined", MakeBool(env, session.joined));
    SetNamed(env, result, "moderator", MakeBool(env, session.moderator));
    SetNamed(env, result, "hosting", MakeBool(env, session.hosting));
    SetNamed(env, result, "roomName", MakeString(env, session.room_name));
    SetNamed(env, result, "memberSlots", MakeNumber(env, session.member_slots));
    napi_value members;
    napi_create_array(env, &members);
    for (size_t i = 0; i < session.members.size(); i++) {
        napi_value m;
        napi_create_object(env, &m);
        SetNamed(env, m, "nickname", MakeString(env, session.members[i].nickname));
        SetNamed(env, m, "username", MakeString(env, session.members[i].username));
        SetNamed(env, m, "gameName", MakeString(env, session.members[i].game_name));
        napi_set_element(env, members, static_cast<uint32_t>(i), m);
    }
    SetNamed(env, result, "members", members);
    napi_value bans;
    napi_create_array(env, &bans);
    for (size_t i = 0; i < session.username_bans.size(); i++) {
        napi_set_element(env, bans, static_cast<uint32_t>(i),
                         MakeString(env, session.username_bans[i]));
    }
    SetNamed(env, result, "usernameBans", bans);
    return result;
}

napi_value MultiplayerKickUser(napi_env env, napi_callback_info info) {
    napi_value args[1];
    size_t argc = 1;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string username;
    if (GetString(env, args[0], username)) {
        CoreBridge::Get().MultiplayerKickUser(username);
    }
    return MakeUndefined(env);
}

napi_value MultiplayerBanUser(napi_env env, napi_callback_info info) {
    napi_value args[1];
    size_t argc = 1;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string username;
    if (GetString(env, args[0], username)) {
        CoreBridge::Get().MultiplayerBanUser(username);
    }
    return MakeUndefined(env);
}

napi_value MultiplayerUnbanUser(napi_env env, napi_callback_info info) {
    napi_value args[1];
    size_t argc = 1;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string username;
    if (GetString(env, args[0], username)) {
        CoreBridge::Get().MultiplayerUnbanUser(username);
    }
    return MakeUndefined(env);
}

napi_value MultiplayerSendChatMessage(napi_env env, napi_callback_info info) {
    napi_value args[1];
    size_t argc = 1;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string message;
    if (GetString(env, args[0], message)) {
        CoreBridge::Get().MultiplayerSendChatMessage(message);
    }
    return MakeUndefined(env);
}

napi_value PollMultiplayerEvents(napi_env env, napi_callback_info info) {
    const auto events = CoreBridge::Get().PollMultiplayerEvents();
    napi_value array;
    napi_create_array(env, &array);
    for (size_t i = 0; i < events.size(); i++) {
        napi_set_element(env, array, static_cast<uint32_t>(i), MakeString(env, events[i]));
    }
    return array;
}

napi_value GetMultiplayerRooms(napi_env env, napi_callback_info info) {
    const auto rooms = CoreBridge::Get().ListMultiplayerRooms();
    napi_value array;
    napi_create_array_with_length(env, rooms.size(), &array);
    for (std::size_t i = 0; i < rooms.size(); ++i) {
        napi_set_element(env, array, static_cast<uint32_t>(i), MultiplayerRoomInfoToNapi(env, rooms[i]));
    }
    return array;
}

napi_value GetSystemProfile(napi_env env, napi_callback_info info) {
    return SystemProfileToNapi(env, CoreBridge::Get().GetSystemProfile());
}

napi_value SetSystemProfile(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_valuetype type;
    if (argc < 1 || napi_typeof(env, args[0], &type) != napi_ok || type != napi_object) {
        return MakeBool(env, false);
    }

    SystemProfile profile = CoreBridge::Get().GetSystemProfile();
    std::string string_value;
    int32_t int_value = 0;
    bool bool_value = false;
    if (GetNamedString(env, args[0], "username", string_value)) {
        profile.username = string_value;
    }
    if (GetNamedInt32(env, args[0], "birthMonth", int_value)) {
        profile.birth_month = static_cast<uint8_t>(std::clamp(int_value, 1, 12));
    }
    if (GetNamedInt32(env, args[0], "birthDay", int_value)) {
        profile.birth_day = static_cast<uint8_t>(std::clamp(int_value, 1, 31));
    }
    if (GetNamedInt32(env, args[0], "language", int_value)) {
        profile.language = static_cast<uint8_t>(std::clamp(int_value, 0, 11));
    }
    if (GetNamedInt32(env, args[0], "soundOutputMode", int_value)) {
        profile.sound_output_mode = static_cast<uint8_t>(std::clamp(int_value, 0, 2));
    }
    if (GetNamedInt32(env, args[0], "countryCode", int_value)) {
        profile.country_code = static_cast<uint8_t>(std::clamp(int_value, 0, 186));
    }
    if (GetNamedBool(env, args[0], "systemSetupNeeded", bool_value)) {
        profile.system_setup_needed = bool_value;
    }
    if (GetNamedInt32(env, args[0], "playCoins", int_value)) {
        profile.play_coins = static_cast<uint16_t>(std::clamp(int_value, 0, 300));
    }
    if (GetNamedString(env, args[0], "macAddress", string_value)) {
        profile.mac_address = string_value;
    }

    return MakeBool(env, CoreBridge::Get().SetSystemProfile(profile));
}

napi_value RegenerateConsoleId(napi_env env, napi_callback_info info) {
    return MakeString(env, CoreBridge::Get().RegenerateConsoleId());
}

napi_value RegenerateMacAddress(napi_env env, napi_callback_info info) {
    return MakeString(env, CoreBridge::Get().RegenerateMacAddress());
}

napi_value GetCountryCompatibility(napi_env env, napi_callback_info info) {
    int region = 0;
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc >= 1 && argv[0] != nullptr) {
        double value = 0;
        if (napi_get_value_double(env, argv[0], &value) == napi_ok) {
            region = static_cast<int>(value);
        }
    }
    return MakeNumber(env, CoreBridge::Get().GetCountryCompatibility(region));
}

napi_value IsFullConsoleLinked(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().IsFullConsoleLinked());
}

napi_value UnlinkConsole(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().UnlinkConsole());
}

napi_value GetSystemFilesStatus(napi_env env, napi_callback_info info) {
    return SystemFilesStatusToNapi(env, CoreBridge::Get().GetSystemFilesStatus());
}

napi_value UninstallSystemFiles(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool old3ds = false;
    if (argc < 1 || !GetBool(env, args[0], old3ds)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().UninstallSystemFiles(old3ds));
}

napi_value GetTitleContentStatus(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string title_id;
    if (argc < 1 || !GetString(env, args[0], title_id)) {
        return TitleContentStatusToNapi(env, {});
    }
    return TitleContentStatusToNapi(env, CoreBridge::Get().GetTitleContentStatus(title_id));
}

napi_value UninstallTitleContent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string title_id;
    int32_t content_kind = 0;
    if (argc < 2 || !GetString(env, args[0], title_id) || !GetInt32(env, args[1], content_kind)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().UninstallTitleContent(title_id, content_kind));
}

napi_value DumpRomFS(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc < 1 || !GetString(env, args[0], path)) {
        return RomFsDumpResultToNapi(env, {});
    }
    return RomFsDumpResultToNapi(env, CoreBridge::Get().DumpRomFS(path));
}

napi_value GetMovieStatus(napi_env env, napi_callback_info info) {
    return MovieStatusToNapi(env, CoreBridge::Get().GetMovieStatus());
}

napi_value GetMovieMetadata(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc < 1 || !GetString(env, args[0], path)) {
        return MovieMetadataToNapi(env, {});
    }
    return MovieMetadataToNapi(env, CoreBridge::Get().GetMovieMetadata(path));
}

napi_value SaveMovie(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().SaveMovie());
}

napi_value CloseMovie(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().CloseMovie());
}

napi_value SetConfig(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string key;
    ConfigValue value;
    if (argc < 2 || !GetString(env, args[0], key) || !NapiToConfigValue(env, args[1], value)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().SetConfig(key, std::move(value)));
}

napi_value GetConfig(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string key;
    if (argc < 1 || !GetString(env, args[0], key)) {
        return MakeUndefined(env);
    }

    const auto value = CoreBridge::Get().GetConfig(key);
    if (!value.has_value()) {
        return MakeUndefined(env);
    }
    return ConfigValueToNapi(env, value.value());
}

napi_value ApplyConfig(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().ApplyConfig());
}

napi_value SaveConfig(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().SaveConfig());
}

napi_value SetTemporaryFrameLimit(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double speed = 0.0;
    if (argc < 1 || !GetDouble(env, args[0], speed)) {
        return MakeBool(env, false);
    }
    return MakeBool(env, CoreBridge::Get().SetTemporaryFrameLimit(speed));
}

napi_value DisableTemporaryFrameLimit(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().DisableTemporaryFrameLimit());
}

napi_value RunNativeTests(napi_env env, napi_callback_info info) {
#ifdef AZAHAR_OHOS_TESTS
    size_t argc = 1;
    napi_value args[1]{};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string filter;
    if (argc > 0) {
        char buf[512]{};
        size_t len = 0;
        napi_get_value_string_utf8(env, args[0], buf, sizeof(buf) - 1, &len);
        filter.assign(buf, len);
    }
    static std::atomic<bool> tests_running{false};
    if (tests_running.exchange(true)) {
        return MakeString(env, "already running");
    }
    std::thread([filter = std::move(filter)] {
        AzaharOhosRunNativeTests(filter);
        tests_running = false;
    }).detach();
    return MakeString(env, "started; see AzaharNativeTests hilog");
#else
    return MakeString(env, "tests not built");
#endif
}

napi_value RunAsmCrashProbe(napi_env env, napi_callback_info info) {
#ifdef AZAHAR_OHOS_TESTS
    std::thread([] { AzaharOhosAsmCrashProbe(); }).detach();
    return MakeString(env, "started");
#else
    return MakeString(env, "tests not built");
#endif
}

napi_value GetPerfStats(napi_env env, napi_callback_info info) {
    const auto stats = CoreBridge::Get().GetPerfStats();
    napi_value array;
    napi_create_array_with_length(env, stats.size(), &array);
    for (size_t i = 0; i < stats.size(); i++) {
        napi_set_element(env, array, static_cast<uint32_t>(i), MakeNumber(env, stats[i]));
    }
    return array;
}

napi_value UpdateDeviceProfile(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string device_type = "phone";
    bool tablet_jit_user_enabled = false;
    if (argc >= 1) {
        GetString(env, args[0], device_type);
    }
    if (argc >= 2) {
        GetBool(env, args[1], tablet_jit_user_enabled);
    }

    return MakeBool(env, CoreBridge::Get().UpdateDeviceProfile(
                             std::move(device_type), tablet_jit_user_enabled));
}

napi_value IsJitSupported(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string device_type = "phone";
    if (argc >= 1) {
        GetString(env, args[0], device_type);
    }

    return MakeBool(env, CoreBridge::Get().IsJitSupported(device_type));
}

napi_value IsJitAvailable(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().IsJitAvailable());
}

napi_value GetRuntimeInfo(napi_env env, napi_callback_info info) {
    return RuntimeInfoToNapi(env, CoreBridge::Get().GetRuntimeInfo());
}

napi_value GetGraphicsInfo(napi_env env, napi_callback_info info) {
    return GraphicsInfoToNapi(env, Azahar::Ohos::ProbeGraphicsInfo());
}

napi_value GetScreenLayout(napi_env env, napi_callback_info info) {
    const auto layout = CoreBridge::Get().GetScreenLayout();
    napi_value array;
    napi_create_array_with_length(env, layout.size(), &array);
    for (size_t i = 0; i < layout.size(); i++) {
        napi_set_element(env, array, static_cast<uint32_t>(i), MakeNumber(env, layout[i]));
    }
    return array;
}

napi_value SetScreenOffsets(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double values[4] = {0, 0, 0, 0};
    for (size_t i = 0; i < argc && i < 4; i++) {
        napi_get_value_double(env, args[i], &values[i]);
    }
    CoreBridge::Get().SetScreenOffsets(static_cast<int32_t>(values[0]),
                                     static_cast<int32_t>(values[1]),
                                     static_cast<int32_t>(values[2]),
                                     static_cast<int32_t>(values[3]));
    return nullptr;
}

napi_value SetCustomScreenRects(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::array<double, 8> values {};
    for (size_t i = 0; i < argc && i < 8; i++) {
        napi_get_value_double(env, args[i], &values[i]);
    }
    CoreBridge::Get().SetCustomScreenRects(values);
    return nullptr;
}

napi_value ClearCustomScreenRects(napi_env env, napi_callback_info info) {
    CoreBridge::Get().ClearCustomScreenRects();
    return nullptr;
}

napi_value GetAppInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc >= 1) {
        GetString(env, args[0], path);
    }
    return AppInfoToNapi(env, CoreBridge::Get().GetAppInfo(path));
}

napi_value GetGameMetadata(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string path;
    if (argc >= 1) {
        GetString(env, args[0], path);
    }
    return GameMetadataToNapi(env, CoreBridge::Get().GetGameMetadata(path));
}

napi_value GetSupportedExtensions(napi_env env, napi_callback_info info) {
    const std::vector<std::string> extensions = CoreBridge::Get().GetSupportedExtensions();
    napi_value array;
    napi_create_array_with_length(env, extensions.size(), &array);
    for (uint32_t i = 0; i < extensions.size(); ++i) {
        napi_set_element(env, array, i, MakeString(env, extensions[i]));
    }
    return array;
}

napi_value IsAudioEnabled(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().IsAudioEnabled());
}

napi_value IsGraphicsEnabled(napi_env env, napi_callback_info info) {
    return MakeBool(env, CoreBridge::Get().IsGraphicsEnabled());
}

bool TryGetXComponentFromObject(napi_env env, napi_value object) {
    napi_value export_instance = nullptr;
    napi_status status =
        napi_get_named_property(env, object, OH_NATIVE_XCOMPONENT_OBJ, &export_instance);
    if (status != napi_ok || export_instance == nullptr) {
        return false;
    }

    napi_valuetype type;
    napi_typeof(env, export_instance, &type);
    if (type == napi_undefined || type == napi_null) {
        return false;
    }

    OH_NativeXComponent* component = nullptr;
    status = napi_unwrap(env, export_instance, reinterpret_cast<void**>(&component));
    if (status != napi_ok || !component) {
        return false;
    }

    return Azahar::Ohos::InitializeXComponentBridge(component, "exports");
}

napi_value RegisterXComponent(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string xcomponent_id;
    if (argc >= 1) {
        GetString(env, args[0], xcomponent_id);
    }

    CoreBridge::Get().RegisterXComponentId(xcomponent_id);

    bool initialized_from_context = false;
    if (argc >= 2) {
        napi_valuetype context_type;
        if (napi_typeof(env, args[1], &context_type) == napi_ok && context_type == napi_object) {
            initialized_from_context = TryGetXComponentFromObject(env, args[1]);
        }
    }

    bool initialized_from_exports = initialized_from_context;
    if (g_saved_exports_ref) {
        napi_value saved_exports = nullptr;
        if (!initialized_from_exports &&
            napi_get_reference_value(env, g_saved_exports_ref, &saved_exports) == napi_ok &&
            saved_exports) {
            initialized_from_exports = TryGetXComponentFromObject(env, saved_exports);
        }
    }

    const RuntimeInfo runtime_info = CoreBridge::Get().GetRuntimeInfo();
    return MakeBool(env, initialized_from_exports || runtime_info.surface.ready);
}

} // namespace

extern "C" __attribute__((visibility("default"), used)) void NativeXComponentInit(
    OH_NativeXComponent* component) {
    AZ_LOGI("NativeXComponentInit called");
    if (!Azahar::Ohos::InitializeXComponentBridge(component, "NativeXComponentInit")) {
        AZ_LOGE("NativeXComponentInit failed to register callbacks");
    }
}

namespace {

napi_value Init(napi_env env, napi_value exports) {
    if (g_saved_exports_ref == nullptr) {
        napi_create_reference(env, exports, 1, &g_saved_exports_ref);
    }

    TryGetXComponentFromObject(env, exports);

    napi_property_descriptor desc[] = {
        {"initEmulator", nullptr, InitEmulator, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shutdownEmulator", nullptr, ShutdownEmulator, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadApplication", nullptr, LoadApplication, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startEmulation", nullptr, StartEmulation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pauseEmulation", nullptr, PauseEmulation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resumeEmulation", nullptr, ResumeEmulation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"doFrame", nullptr, DoFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopEmulation", nullptr, StopEmulation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resetEmulation", nullptr, ResetEmulation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isPaused", nullptr, IsPaused, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"consumeCameraPermissionRequest", nullptr, ConsumeCameraPermissionRequest, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"consumeMicPermissionRequest", nullptr, ConsumeMicPermissionRequest, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"consumeStillImagePickRequest", nullptr, ConsumeStillImagePickRequest, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"consumeCoreError", nullptr, ConsumeCoreError, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"setStillImagePath", nullptr, SetStillImagePath, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"getCameraDevices", nullptr, GetCameraDevices, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"startGamepadInputCapture", nullptr, StartGamepadInputCapture, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"startGamepadAxisCapture", nullptr, StartGamepadAxisCapture, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"cancelGamepadInputCapture", nullptr, CancelGamepadInputCapture, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"consumeGamepadInputCapture", nullptr, ConsumeGamepadInputCapture, nullptr, nullptr,
         nullptr, napi_default, nullptr},
        {"getGamepadTestState", nullptr, GetGamepadTestState, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"resetGamepadTestState", nullptr, ResetGamepadTestState, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"getGamepadPressedKeys", nullptr, GetGamepadPressedKeys, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"getGamepadAnalogState", nullptr, GetGamepadAnalogState, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"sendTouchEvent", nullptr, SendTouchEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendKeyEvent", nullptr, SendKeyEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"sendAnalogEvent", nullptr, SendAnalogEvent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setShellOpen", nullptr, SetShellOpen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getShellOpen", nullptr, GetShellOpen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSystemSleepState", nullptr, GetSystemSleepState, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"setScreenRotation", nullptr, SetScreenRotation, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveState", nullptr, SaveState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadState", nullptr, LoadState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSaveStateInfo", nullptr, GetSaveStateInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"deleteState", nullptr, DeleteState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hasUndoState", nullptr, HasUndoState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"undoState", nullptr, UndoState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"captureScreenshot", nullptr, CaptureScreenshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"installCIA", nullptr, InstallCIA, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getInstalledGamePaths", nullptr, GetInstalledGamePaths, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCheats", nullptr, GetCheats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hasGamePerfHacks", nullptr, HasGamePerfHacks, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCheatEnabled", nullptr, SetCheatEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"upsertGatewayCheat", nullptr, UpsertGatewayCheat, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"removeCheat", nullptr, RemoveCheat, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"importCheats", nullptr, ImportCheats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"validateGatewayCheatCode", nullptr, ValidateGatewayCheatCode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isSearchingForAmiibo", nullptr, IsSearchingForAmiibo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadAmiibo", nullptr, LoadAmiibo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"removeAmiibo", nullptr, RemoveAmiibo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"makeAmiiboFile", nullptr, MakeAmiiboFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"zipPassExport", nullptr, ZipPassExport, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"zipPassImport", nullptr, ZipPassImport, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"zipPassImportQueued", nullptr, ZipPassImportQueued, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"zipPassClearStreetPass", nullptr, ZipPassClearStreetPass, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMultiplayerRooms", nullptr, GetMultiplayerRooms, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"multiplayerJoinRoom", nullptr, MultiplayerJoinRoom, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"multiplayerCreateRoom", nullptr, MultiplayerCreateRoom, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"multiplayerLeaveRoom", nullptr, MultiplayerLeaveRoom, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMultiplayerSessionInfo", nullptr, GetMultiplayerSessionInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"multiplayerKickUser", nullptr, MultiplayerKickUser, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"multiplayerBanUser", nullptr, MultiplayerBanUser, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"multiplayerUnbanUser", nullptr, MultiplayerUnbanUser, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"multiplayerSendChatMessage", nullptr, MultiplayerSendChatMessage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pollMultiplayerEvents", nullptr, PollMultiplayerEvents, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSystemProfile", nullptr, GetSystemProfile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setSystemProfile", nullptr, SetSystemProfile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"regenerateConsoleId", nullptr, RegenerateConsoleId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"regenerateMacAddress", nullptr, RegenerateMacAddress, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCountryCompatibility", nullptr, GetCountryCompatibility, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isFullConsoleLinked", nullptr, IsFullConsoleLinked, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"unlinkConsole", nullptr, UnlinkConsole, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSystemFilesStatus", nullptr, GetSystemFilesStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"uninstallSystemFiles", nullptr, UninstallSystemFiles, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getTitleContentStatus", nullptr, GetTitleContentStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"uninstallTitleContent", nullptr, UninstallTitleContent, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"dumpRomFS", nullptr, DumpRomFS, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMovieStatus", nullptr, GetMovieStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getMovieMetadata", nullptr, GetMovieMetadata, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveMovie", nullptr, SaveMovie, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"closeMovie", nullptr, CloseMovie, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setConfig", nullptr, SetConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getConfig", nullptr, GetConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"applyConfig", nullptr, ApplyConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"saveConfig", nullptr, SaveConfig, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setTemporaryFrameLimit", nullptr, SetTemporaryFrameLimit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"disableTemporaryFrameLimit", nullptr, DisableTemporaryFrameLimit, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPerfStats", nullptr, GetPerfStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runNativeTests", nullptr, RunNativeTests, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"asmCrashProbe", nullptr, RunAsmCrashProbe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"updateDeviceProfile", nullptr, UpdateDeviceProfile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isJitSupported", nullptr, IsJitSupported, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isJitAvailable", nullptr, IsJitAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRuntimeInfo", nullptr, GetRuntimeInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getGraphicsInfo", nullptr, GetGraphicsInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getScreenLayout", nullptr, GetScreenLayout, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setScreenOffsets", nullptr, SetScreenOffsets, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCustomScreenRects", nullptr, SetCustomScreenRects, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearCustomScreenRects", nullptr, ClearCustomScreenRects, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAppInfo", nullptr, GetAppInfo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getGameMetadata", nullptr, GetGameMetadata, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSupportedExtensions", nullptr, GetSupportedExtensions, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isAudioEnabled", nullptr, IsAudioEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isGraphicsEnabled", nullptr, IsGraphicsEnabled, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"registerXComponent", nullptr, RegisterXComponent, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    AZ_LOGI("Azahar OHOS NAPI module initialized");
    return exports;
}

static napi_module azahar_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "azahar_ohos",
    .nm_priv = nullptr,
    .reserved = {0},
};

} // namespace

extern "C" __attribute__((constructor, visibility("default"), used)) void RegisterAzaharModule() {
    AZ_LOGI("RegisterAzaharModule called");
    napi_module_register(&azahar_module);
}

#ifdef NAPI_MODULE
NAPI_MODULE(azahar_ohos, Init)
#endif
