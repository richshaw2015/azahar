#include "ohos_xcomponent_bridge.h"

#include "../core/azahar_core_bridge.h"

#include <cstring>

namespace Azahar::Ohos {

namespace {

OH_NativeXComponent* g_component = nullptr;
OH_NativeXComponent_Callback g_callback {};
bool g_callback_initialized = false;

void OnSurfaceCreatedCB(OH_NativeXComponent* component, void* window) {
    g_component = component;
    CoreBridge::Get().OnSurfaceCreated(component, window);
}

void OnSurfaceChangedCB(OH_NativeXComponent* component, void* window) {
    if (g_component && component != g_component) {
        return;
    }
    CoreBridge::Get().OnSurfaceChanged(component, window);
}

void OnSurfaceDestroyedCB(OH_NativeXComponent* component, void* window) {
    if (g_component && component != g_component) {
        return;
    }
    CoreBridge::Get().OnSurfaceDestroyed();
    g_component = nullptr;
}

void DispatchTouchEventCB(OH_NativeXComponent* component, void* window) {
    if (g_component && component != g_component) {
        return;
    }

    OH_NativeXComponent_TouchEvent touch_event {};
    if (OH_NativeXComponent_GetTouchEvent(component, window, &touch_event) !=
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        return;
    }

    int32_t action = -1;
    switch (touch_event.type) {
    case OH_NATIVEXCOMPONENT_DOWN:
        action = 0;
        break;
    case OH_NATIVEXCOMPONENT_MOVE:
        action = 1;
        break;
    case OH_NATIVEXCOMPONENT_UP:
    case OH_NATIVEXCOMPONENT_CANCEL:
        action = 2;
        break;
    default:
        return;
    }

    CoreBridge::Get().SendTouchEvent(touch_event.x, touch_event.y, action);
}

void InitCallbackStruct() {
    if (g_callback_initialized) {
        return;
    }
    std::memset(&g_callback, 0, sizeof(g_callback));
    g_callback.OnSurfaceCreated = OnSurfaceCreatedCB;
    g_callback.OnSurfaceChanged = OnSurfaceChangedCB;
    g_callback.OnSurfaceDestroyed = OnSurfaceDestroyedCB;
    g_callback.DispatchTouchEvent = DispatchTouchEventCB;
    g_callback_initialized = true;
}

} // namespace

bool InitializeXComponentBridge(OH_NativeXComponent* component, const char* source) {
    if (!component) {
        return false;
    }

    InitCallbackStruct();
    g_component = component;

    char id[OH_XCOMPONENT_ID_LEN_MAX + 1] {};
    uint64_t id_size = OH_XCOMPONENT_ID_LEN_MAX + 1;
    if (OH_NativeXComponent_GetXComponentId(component, id, &id_size) ==
        OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        CoreBridge::Get().RegisterXComponentId(id);
    }

    const int32_t ret = OH_NativeXComponent_RegisterCallback(component, &g_callback);
    return ret == OH_NATIVEXCOMPONENT_RESULT_SUCCESS;
}

void ResetXComponentBridge() {
    g_component = nullptr;
    CoreBridge::Get().OnSurfaceDestroyed();
}

} // namespace Azahar::Ohos
