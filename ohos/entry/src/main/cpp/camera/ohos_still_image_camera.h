// Copyright 2020-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#pragma once

#include <memory>
#include <string>
#include <vector>
#include "common/common_types.h"
#include "core/frontend/camera/factory.h"
#include "core/frontend/camera/interface.h"
#include "core/hle/service/cam/cam.h"

namespace Camera::OhosStillImage {

// ArkTS-side picker handshake, mirroring Android's StillImageCameraHelper:
// Create() sets the pending flag when no image path is cached; the frontend
// polls ConsumeStillImagePickRequest, opens the system file picker and calls
// SetStillImagePath with the picked file's real path, then reloads the camera
// devices. The cached path is cleared when the Interface is destroyed, so the
// picker is shown again on the next camera session, same as Android.
void NotifyStillImagePickNeeded();
bool ConsumeStillImagePickRequest();
void SetStillImagePath(const std::string& path);

class Interface final : public CameraInterface {
public:
    explicit Interface(std::string path, const Service::CAM::Flip& flip);
    ~Interface() override;
    void StartCapture() override;
    void StopCapture() override {};
    void SetResolution(const Service::CAM::Resolution& resolution) override;
    void SetFlip(Service::CAM::Flip flip) override;
    void SetEffect(Service::CAM::Effect effect) override {};
    void SetFormat(Service::CAM::OutputFormat format) override;
    void SetFrameRate(Service::CAM::FrameRate frame_rate) override {};
    std::vector<u16> ReceiveFrame() override;
    bool IsPreviewAvailable() override;

private:
    std::string path;
    Service::CAM::Resolution resolution{};

    // Flipping parameters. mirror = horizontal, invert = vertical.
    bool base_mirror{};
    bool base_invert{};
    bool mirror{};
    bool invert{};

    Service::CAM::OutputFormat format = Service::CAM::OutputFormat::RGB565;
    std::vector<u16> image; // Data fetched from the frontend
    bool opened{};          // Whether the camera was successfully opened
};

class Factory final : public CameraFactory {
public:
    std::unique_ptr<CameraInterface> Create(const std::string& config,
                                            const Service::CAM::Flip& flip) override;
};

} // namespace Camera::OhosStillImage
