// Copyright 2020-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#pragma once

#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <ohcamera/camera.h>
#include "common/common_types.h"
#include "core/frontend/camera/factory.h"
#include "core/frontend/camera/interface.h"
#include "core/hle/service/cam/cam.h"

typedef struct Camera_Input Camera_Input;
typedef struct Camera_CaptureSession Camera_CaptureSession;
typedef struct Camera_PreviewOutput Camera_PreviewOutput;
struct OH_ImageReceiverNative;

namespace Camera::Ohos {

// Placeholders to mean 'use any front/back camera', same as Android.
constexpr const char* FrontCameraPlaceholder = "_front";
constexpr const char* BackCameraPlaceholder = "_back";

// Camera permission handshake with the ArkTS frontend. NotifyCameraPermissionNeeded
// is called once per session when a capture attempt finds ohos.permission.CAMERA
// missing; ConsumeCameraPermissionRequest is polled by the frontend, which then
// shows the system permission dialog and reloads the camera devices.
void NotifyCameraPermissionNeeded();
bool ConsumeCameraPermissionRequest();

// Physical camera enumeration for the settings page device picker, mirroring
// Android's cameraIdList + LENS_FACING query.
struct OhosCameraDeviceInfo {
    std::string id;
    uint32_t position = 0;   // Camera_Position
    uint32_t type = 0;       // Camera_Type
    uint32_t connection = 0; // Camera_Connection
};

std::vector<OhosCameraDeviceInfo> EnumerateCameraDevices();

class Interface final : public CameraInterface {
public:
    explicit Interface(std::string device_spec, const Service::CAM::Flip& flip);
    ~Interface() override;
    void StartCapture() override;
    void StopCapture() override;
    void SetResolution(const Service::CAM::Resolution& resolution) override;
    void SetFlip(Service::CAM::Flip flip) override;
    void SetEffect(Service::CAM::Effect effect) override {};
    void SetFormat(Service::CAM::OutputFormat format) override;
    void SetFrameRate(Service::CAM::FrameRate frame_rate) override {};
    std::vector<u16> ReceiveFrame() override;
    bool IsPreviewAvailable() override;

    void OnImageArrive();

private:
    bool EnsurePipeline();
    void ShutdownPipeline();

    const std::string device_spec;

    Camera_Manager* manager = nullptr;
    Camera_Input* input = nullptr;
    Camera_CaptureSession* session = nullptr;
    Camera_PreviewOutput* preview = nullptr;
    OH_ImageReceiverNative* receiver = nullptr;
    bool input_open = false;
    bool session_ready = false;
    bool capturing = false;

    uint32_t sensor_orientation = 0;
    int source_width = 0;
    int source_height = 0;

    Service::CAM::Resolution resolution{};

    // Flipping parameters. mirror = horizontal, invert = vertical.
    bool base_mirror{};
    bool base_invert{};
    bool mirror{};
    bool invert{};

    Service::CAM::OutputFormat format = Service::CAM::OutputFormat::YUV422;

    // Latest frame copied out of the image receiver, packed NV21.
    std::mutex frame_mutex;
    std::vector<u8> nv21_frame;
    bool has_frame = false;
};

class Factory final : public CameraFactory {
public:
    std::unique_ptr<CameraInterface> Create(const std::string& config,
                                            const Service::CAM::Flip& flip) override;
};

} // namespace Camera::Ohos
