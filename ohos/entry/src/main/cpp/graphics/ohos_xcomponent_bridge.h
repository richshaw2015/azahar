#pragma once

#include <ace/xcomponent/native_interface_xcomponent.h>

namespace Azahar::Ohos {

bool InitializeXComponentBridge(OH_NativeXComponent* component, const char* source);
void ResetXComponentBridge();

} // namespace Azahar::Ohos
