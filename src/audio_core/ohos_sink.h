// Copyright Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the license.txt file included.

#pragma once

#include <cstddef>
#include <memory>
#include <string>
#include <vector>

#include "audio_core/sink.h"

namespace AudioCore {

class OhosSink final : public Sink {
public:
    explicit OhosSink(std::string_view device_id);
    ~OhosSink() override;

    unsigned int GetNativeSampleRate() const override;
    void SetCallback(std::function<void(s16*, std::size_t)> cb) override;

    void Pause() override;
    void Resume() override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};

std::vector<std::string> ListOhosSinkDevices();

} // namespace AudioCore
