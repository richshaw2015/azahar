#pragma once

#include <cstdint>

namespace Azahar::Ohos::Input {

constexpr int kCirclePadAnalog = 100;
constexpr int kCStickAnalog = 101;

void EnsureInitialized();
void Shutdown();
void ApplyDefaultProfile();

bool SetButtonState(int32_t native_button, bool pressed);
bool SetAnalogState(int32_t analog, float x, float y);
bool SetScreenRotation(int32_t rotation);
void ReleaseAll();

} // namespace Azahar::Ohos::Input
