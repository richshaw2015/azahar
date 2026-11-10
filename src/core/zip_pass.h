// Copyright 2026 Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#pragma once

#include <string>

namespace Core {

int exportZipPass(std::string path);

int importZipPass(std::string path);

int importQueuedZipPass();

void trimZipPassHistory();

int clearStreetPassConfig();

} // namespace Core
