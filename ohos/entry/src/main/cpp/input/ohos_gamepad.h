#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "core/azahar_core_bridge.h"

namespace Azahar::Ohos::Gamepad {

bool Initialize();
void Shutdown();

// Rebuilds the physical→3DS button map, analog source routing and deadzone from
// the bridge config map. Invoked by CoreBridge::ApplyConfig so remapping takes
// effect live, including while a game is running.
void ApplyConfig(const std::unordered_map<std::string, ConfigValue>& config);

// Binding capture used by the settings page: while armed, the next gamepad
// button DOWN is swallowed (not dispatched to the game) and stashed for
// ConsumeInputCapture to return once. Its matching UP is also swallowed.
// StartAxisInputCapture instead records the first axis deflected past the
// capture threshold, packed as 30000 + source*100 + component*10 + dir.
void StartInputCapture();
void StartAxisInputCapture();
void CancelInputCapture();
int32_t ConsumeInputCapture();

// Snapshot of raw gamepad input for the settings-page tester tab, returned as
// JSON: {"online":bool,"name":str,"last":code,"pressed":[codes...],
//        "axes":[lx,ly,rx,ry,hatX,hatY],"triggers":[lt,rt],"now":ms,
//        "events":[[seq,code,down,ms]...]} — raw values before mapping/deadzone.
// Only button edges with seq > since_seq are included.
std::string GetTestStateJson(uint32_t since_seq);
// Clears the tester's event log (live state is untouched).
void ResetTestState();

// Native-button ids (Settings::NativeButton) currently held by gamepad input,
// resolved through the live mapping (buttons + axis-driven dpad). The ArkTS
// virtual pad polls this to render pressed-state feedback for physical input.
std::vector<int32_t> GetPressedButtons();

// Current 3DS analog values driven by gamepad input (post deadzone/mapping),
// {circlepad_x, circlepad_y, cstick_x, cstick_y}. The ArkTS virtual pad polls
// this to move the on-screen sticks with the physical ones.
std::vector<float> GetAnalogState();

} // namespace Azahar::Ohos::Gamepad
