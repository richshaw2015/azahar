// Copyright 2020-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include <accesstoken/ability_access_control.h>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <libyuv.h>
#include <multimedia/image_framework/image/image_native.h>
#include <multimedia/image_framework/image/image_receiver_native.h>
#include <native_buffer/native_buffer.h>
#include <ohcamera/camera_device.h>
#include <ohcamera/camera_input.h>
#include <ohcamera/camera_manager.h>
#include <ohcamera/capture_session.h>
#include <ohcamera/preview_output.h>
#include "camera/ohos_camera.h"
#include "common/logging/log.h"
#include "core/frontend/camera/blank_camera.h"

namespace Camera::Ohos {

namespace {

struct YUVImage {
    int width{};
    int height{};
    std::vector<u8> y;
    std::vector<u8> u;
    std::vector<u8> v;

    explicit YUVImage(int width_, int height_)
        : width(width_), height(height_), y(static_cast<std::size_t>(width * height)),
          u(static_cast<std::size_t>(width * height / 4)),
          v(static_cast<std::size_t>(width * height / 4)) {}

    void Swap(YUVImage& other) {
        y.swap(other.y);
        u.swap(other.u);
        v.swap(other.v);
        std::swap(width, other.width);
        std::swap(height, other.height);
    }

    void Clear() {
        y.clear();
        u.clear();
        v.clear();
        width = height = 0;
    }
};

#define YUV(image)                                                                                 \
    image.y.data(), image.width, image.u.data(), image.width / 2, image.v.data(), image.width / 2

// Selects a camera device: "" uses the first device, "_front"/"_back" match by
// position, anything else is matched as a literal camera ID.
Camera_Device* SelectDevice(Camera_Device* devices, uint32_t count,
                            const std::string& spec) {
    if (!devices || count == 0) {
        return nullptr;
    }
    if (spec.empty()) {
        return &devices[0];
    }
    for (uint32_t i = 0; i < count; i++) {
        if (devices[i].cameraId && spec == devices[i].cameraId) {
            return &devices[i];
        }
        if (spec == FrontCameraPlaceholder &&
            devices[i].cameraPosition == CAMERA_POSITION_FRONT) {
            return &devices[i];
        }
        if (spec == BackCameraPlaceholder && devices[i].cameraPosition == CAMERA_POSITION_BACK) {
            return &devices[i];
        }
    }
    return nullptr;
}

// Picks the preview profile closest to 640x480, preferring NV21-capable ones.
const Camera_Profile* SelectPreviewProfile(const Camera_OutputCapability* capability) {
    const Camera_Profile* best = nullptr;
    uint64_t best_distance = UINT64_MAX;
    if (!capability || !capability->previewProfiles) {
        return nullptr;
    }
    for (uint32_t i = 0; i < capability->previewProfilesSize; i++) {
        const Camera_Profile* profile = capability->previewProfiles[i];
        if (!profile || profile->size.width == 0 || profile->size.height == 0) {
            continue;
        }
        if (profile->format != CAMERA_FORMAT_YUV_420_SP) {
            continue;
        }
        const uint64_t dw = profile->size.width > 640 ? profile->size.width - 640
                                                    : 640 - profile->size.width;
        const uint64_t dh = profile->size.height > 480 ? profile->size.height - 480
                                                      : 480 - profile->size.height;
        const uint64_t distance = dw * dw + dh * dh;
        if (!best || distance < best_distance) {
            best = profile;
            best_distance = distance;
        }
    }
    return best;
}

void OnImageArriveCallback(OH_ImageReceiverNative* receiver, void* user_data) {
    (void)receiver;
    if (user_data) {
        static_cast<Interface*>(user_data)->OnImageArrive();
    }
}

// One-shot-per-session handshake flags, same semantics as Android's
// camera_permission_requested in ndk_camera.cpp.
std::atomic<bool> camera_permission_requested{false};
std::atomic<bool> camera_permission_pending{false};

} // namespace

void NotifyCameraPermissionNeeded() {
    if (!camera_permission_requested.exchange(true)) {
        camera_permission_pending.store(true);
    }
}

bool ConsumeCameraPermissionRequest() {
    return camera_permission_pending.exchange(false);
}

std::vector<OhosCameraDeviceInfo> EnumerateCameraDevices() {
    std::vector<OhosCameraDeviceInfo> out;
    Camera_Manager* manager = nullptr;
    if (OH_Camera_GetCameraManager(&manager) != CAMERA_OK || manager == nullptr) {
        return out;
    }
    Camera_Device* devices = nullptr;
    uint32_t device_count = 0;
    if (OH_CameraManager_GetSupportedCameras(manager, &devices, &device_count) == CAMERA_OK &&
        devices != nullptr) {
        for (uint32_t i = 0; i < device_count; i++) {
            OhosCameraDeviceInfo info;
            info.id = devices[i].cameraId ? devices[i].cameraId : "";
            info.position = static_cast<uint32_t>(devices[i].cameraPosition);
            info.type = static_cast<uint32_t>(devices[i].cameraType);
            info.connection = static_cast<uint32_t>(devices[i].connectionType);
            out.push_back(std::move(info));
        }
        OH_CameraManager_DeleteSupportedCameras(manager, devices, device_count);
    }
    OH_Camera_DeleteCameraManager(manager);
    return out;
}

Interface::Interface(std::string device_spec_, const Service::CAM::Flip& flip)
    : device_spec(std::move(device_spec_)) {
    mirror = base_mirror =
        flip == Service::CAM::Flip::Horizontal || flip == Service::CAM::Flip::Reverse;
    invert = base_invert =
        flip == Service::CAM::Flip::Vertical || flip == Service::CAM::Flip::Reverse;
}

Interface::~Interface() {
    ShutdownPipeline();
}

bool Interface::EnsurePipeline() {
    if (session_ready) {
        return true;
    }

    if (!OH_AT_CheckSelfPermission("ohos.permission.CAMERA")) {
        // Ask the frontend to show the system permission dialog; after the
        // user responds it reloads the camera devices which retries here.
        NotifyCameraPermissionNeeded();
        LOG_ERROR(Service_CAM, "Camera permission not granted");
        return false;
    }

    if (OH_Camera_GetCameraManager(&manager) != CAMERA_OK || manager == nullptr) {
        LOG_ERROR(Service_CAM, "Failed to create camera manager");
        return false;
    }

    Camera_Device* devices = nullptr;
    uint32_t device_count = 0;
    Camera_OutputCapability* capability = nullptr;
    const Camera_Profile* profile = nullptr;
    Camera_Device* device = nullptr;

    if (OH_CameraManager_GetSupportedCameras(manager, &devices, &device_count) != CAMERA_OK ||
        device_count == 0) {
        LOG_ERROR(Service_CAM, "No camera devices available");
        goto fail;
    }
    device = SelectDevice(devices, device_count, device_spec);
    if (device == nullptr) {
        LOG_ERROR(Service_CAM, "Requested camera \"{}\" not found", device_spec);
        goto fail;
    }
    if (OH_CameraDevice_GetCameraOrientation(device, &sensor_orientation) != CAMERA_OK) {
        sensor_orientation = 0;
    }
    if (OH_CameraManager_GetSupportedCameraOutputCapability(manager, device, &capability) !=
        CAMERA_OK) {
        LOG_ERROR(Service_CAM, "Failed to get camera output capability");
        goto fail;
    }
    profile = SelectPreviewProfile(capability);
    if (profile == nullptr) {
        LOG_ERROR(Service_CAM, "No NV21 preview profile available");
        goto fail;
    }

    // Image receiver produces the preview surface; camera writes NV21 frames into it.
    {
        OH_ImageReceiverOptions* options = nullptr;
        if (OH_ImageReceiverOptions_Create(&options) != IMAGE_SUCCESS) {
            goto fail;
        }
        Image_Size size{profile->size.width, profile->size.height};
        if (OH_ImageReceiverOptions_SetSize(options, size) != IMAGE_SUCCESS ||
            OH_ImageReceiverOptions_SetCapacity(options, 4) != IMAGE_SUCCESS ||
            OH_ImageReceiverNative_Create(options, &receiver) != IMAGE_SUCCESS ||
            receiver == nullptr) {
            OH_ImageReceiverOptions_Release(options);
            goto fail;
        }
        OH_ImageReceiverOptions_Release(options);
    }
    if (OH_ImageReceiverNative_OnImageArrive(receiver, &OnImageArriveCallback, this) !=
        IMAGE_SUCCESS) {
        goto fail;
    }

    if (OH_CameraManager_CreateCameraInput(manager, device, &input) != CAMERA_OK ||
        OH_CameraInput_Open(input) != CAMERA_OK) {
        LOG_ERROR(Service_CAM,
                  "Failed to open camera input (permission may be missing)");
        goto fail;
    }
    input_open = true;

    {
        uint64_t surface_id = 0;
        if (OH_ImageReceiverNative_GetReceivingSurfaceId(receiver, &surface_id) != IMAGE_SUCCESS) {
            goto fail;
        }
        char surface_id_string[32];
        std::snprintf(surface_id_string, sizeof(surface_id_string), "%llu",
                      static_cast<unsigned long long>(surface_id));
        if (OH_CameraManager_CreatePreviewOutput(manager, profile, surface_id_string, &preview) !=
                CAMERA_OK ||
            preview == nullptr) {
            LOG_ERROR(Service_CAM, "Failed to create preview output");
            goto fail;
        }
    }

    if (OH_CameraManager_CreateCaptureSession(manager, &session) != CAMERA_OK ||
        session == nullptr) {
        LOG_ERROR(Service_CAM, "Failed to create capture session");
        goto fail;
    }
    OH_CaptureSession_SetSessionMode(session, NORMAL_PHOTO);
    if (OH_CaptureSession_BeginConfig(session) != CAMERA_OK ||
        OH_CaptureSession_AddInput(session, input) != CAMERA_OK ||
        OH_CaptureSession_AddPreviewOutput(session, preview) != CAMERA_OK ||
        OH_CaptureSession_CommitConfig(session) != CAMERA_OK) {
        LOG_ERROR(Service_CAM, "Failed to configure capture session");
        goto fail;
    }

    source_width = static_cast<int>(profile->size.width);
    source_height = static_cast<int>(profile->size.height);
    session_ready = true;

    if (capability) {
        OH_CameraManager_DeleteSupportedCameraOutputCapability(manager, capability);
    }
    if (devices) {
        OH_CameraManager_DeleteSupportedCameras(manager, devices, device_count);
    }
    return true;

fail:
    if (capability) {
        OH_CameraManager_DeleteSupportedCameraOutputCapability(manager, capability);
    }
    if (devices) {
        OH_CameraManager_DeleteSupportedCameras(manager, devices, device_count);
    }
    ShutdownPipeline();
    return false;
}

void Interface::ShutdownPipeline() {
    capturing = false;
    session_ready = false;

    if (preview) {
        OH_PreviewOutput_Stop(preview);
        OH_PreviewOutput_Release(preview);
        preview = nullptr;
    }
    if (session) {
        OH_CaptureSession_Stop(session);
        OH_CaptureSession_Release(session);
        session = nullptr;
    }
    if (input) {
        if (input_open) {
            OH_CameraInput_Close(input);
            input_open = false;
        }
        OH_CameraInput_Release(input);
        input = nullptr;
    }
    if (receiver) {
        OH_ImageReceiverNative_OffImageArrive(receiver, &OnImageArriveCallback);
        OH_ImageReceiverNative_Release(receiver);
        receiver = nullptr;
    }
    {
        std::lock_guard lock{frame_mutex};
        nv21_frame.clear();
        has_frame = false;
    }
    if (manager) {
        OH_Camera_DeleteCameraManager(manager);
        manager = nullptr;
    }
}

void Interface::StartCapture() {
    if (capturing) {
        return;
    }
    if (!EnsurePipeline()) {
        return;
    }
    if (OH_CaptureSession_Start(session) != CAMERA_OK ||
        OH_PreviewOutput_Start(preview) != CAMERA_OK) {
        LOG_ERROR(Service_CAM, "Failed to start camera capture session");
        return;
    }
    capturing = true;
}

void Interface::StopCapture() {
    if (!capturing) {
        return;
    }
    capturing = false;
    if (preview) {
        OH_PreviewOutput_Stop(preview);
    }
    if (session) {
        OH_CaptureSession_Stop(session);
    }
}

void Interface::OnImageArrive() {
    if (!receiver) {
        return;
    }
    OH_ImageNative* image = nullptr;
    if (OH_ImageReceiverNative_ReadLatestImage(receiver, &image) != IMAGE_SUCCESS ||
        image == nullptr) {
        return;
    }

    uint32_t* types = nullptr;
    size_t type_size = 0;
    if (OH_ImageNative_GetComponentTypes(image, nullptr, &type_size) != IMAGE_SUCCESS ||
        type_size == 0) {
        OH_ImageNative_Release(image);
        return;
    }
    types = static_cast<uint32_t*>(malloc(type_size * sizeof(uint32_t)));
    if (OH_ImageNative_GetComponentTypes(image, &types, &type_size) != IMAGE_SUCCESS) {
        free(types);
        OH_ImageNative_Release(image);
        return;
    }

    const uint32_t component = types[0];
    free(types);

    OH_NativeBuffer* native_buffer = nullptr;
    size_t buffer_size = 0;
    int32_t row_stride = 0;
    if (OH_ImageNative_GetByteBuffer(image, component, &native_buffer) != IMAGE_SUCCESS ||
        native_buffer == nullptr ||
        OH_ImageNative_GetBufferSize(image, component, &buffer_size) != IMAGE_SUCCESS ||
        OH_ImageNative_GetRowStride(image, component, &row_stride) != IMAGE_SUCCESS) {
        OH_ImageNative_Release(image);
        return;
    }

    Image_Size size{};
    OH_ImageNative_GetImageSize(image, &size);
    const int width = static_cast<int>(size.width);
    const int height = static_cast<int>(size.height);

    void* raw = nullptr;
    if (width <= 0 || height <= 0 || OH_NativeBuffer_Map(native_buffer, &raw) != 0 ||
        raw == nullptr) {
        OH_ImageNative_Release(image);
        return;
    }

    // The preview producer delivers a single packed YUV_420_SP (NV21) buffer,
    // possibly with a row stride larger than the width.
    const int packed_rows = height * 3 / 2;
    const int copy_width = std::min<int>(width, row_stride > 0 ? row_stride : width);
    if (buffer_size >= static_cast<size_t>(copy_width) * packed_rows) {
        std::vector<u8> packed(static_cast<size_t>(copy_width) * packed_rows);
        const u8* src = static_cast<const u8*>(raw);
        const int src_stride = row_stride > 0 ? row_stride : width;
        for (int row = 0; row < packed_rows; row++) {
            std::memcpy(packed.data() + static_cast<size_t>(row) * copy_width,
                        src + static_cast<size_t>(row) * src_stride, copy_width);
        }
        std::lock_guard lock{frame_mutex};
        nv21_frame = std::move(packed);
        has_frame = true;
        source_width = copy_width;
        source_height = height;
    }

    OH_NativeBuffer_Unmap(native_buffer);
    OH_ImageNative_Release(image);
}

std::vector<u16> Interface::ReceiveFrame() {
    // Match BlankCamera: 0x8000 is black in YUV422, 0 is black in RGB565.
    const u16 black = format == Service::CAM::OutputFormat::RGB565 ? 0 : 0x8000;
    if (!session_ready || resolution.width == 0 || resolution.height == 0) {
        return std::vector<u16>(resolution.width * resolution.height, black);
    }

    std::vector<u8> nv21;
    int src_width;
    int src_height;
    {
        std::lock_guard lock{frame_mutex};
        if (!has_frame) {
            return std::vector<u16>(resolution.width * resolution.height, black);
        }
        nv21 = nv21_frame;
        src_width = source_width;
        src_height = source_height;
    }

    // Unpack NV21 into I420 planes.
    YUVImage converted(src_width, src_height);
    const u8* src_y = nv21.data();
    const u8* src_vu = nv21.data() + static_cast<size_t>(src_width) * src_height;
    libyuv::NV21ToI420(src_y, src_width, src_vu, src_width, YUV(converted), src_width, src_height);

    // Rotate the frame upright using the sensor orientation.
    int width = src_width;
    int height = src_height;
    const int rotation = static_cast<int>(sensor_orientation) % 360;
    if (rotation == 90 || rotation == 270) {
        std::swap(width, height);
    }
    YUVImage rotated(width, height);
    libyuv::I420Rotate(YUV(converted), YUV(rotated), converted.width, converted.height,
                       static_cast<libyuv::RotationMode>(rotation));
    converted.Clear();

    // Center-crop to the requested aspect ratio, then scale.
    int crop_width{}, crop_height{};
    if (resolution.width * height > resolution.height * width) {
        crop_width = width;
        crop_height = width * resolution.height / resolution.width;
    } else {
        crop_height = height;
        crop_width = height * resolution.width / resolution.height;
    }
    const int crop_x = (width - crop_width) / 2;
    const int crop_y = (height - crop_height) / 2;

    const int y_offset = crop_y * width + crop_x;
    const int uv_offset = crop_y / 2 * width / 2 + crop_x / 2;
    YUVImage scaled(resolution.width, resolution.height);
    libyuv::I420Scale(rotated.y.data() + y_offset, width, rotated.u.data() + uv_offset, width / 2,
                      rotated.v.data() + uv_offset, width / 2, crop_width, crop_height, YUV(scaled),
                      resolution.width, resolution.height, libyuv::kFilterBilinear);
    rotated.Clear();

    if (mirror) {
        YUVImage mirrored(scaled.width, scaled.height);
        libyuv::I420Mirror(YUV(scaled), YUV(mirrored), resolution.width, resolution.height);
        scaled.Swap(mirrored);
    }

    std::vector<u16> output(resolution.width * resolution.height);
    if (format == Service::CAM::OutputFormat::RGB565) {
        libyuv::I420ToRGB565(YUV(scaled), reinterpret_cast<u8*>(output.data()),
                             resolution.width * 2, resolution.width,
                             invert ? -resolution.height : resolution.height);
    } else {
        libyuv::I420ToYUY2(YUV(scaled), reinterpret_cast<u8*>(output.data()), resolution.width * 2,
                           resolution.width, invert ? -resolution.height : resolution.height);
    }
    return output;
}

bool Interface::IsPreviewAvailable() {
    std::lock_guard lock{frame_mutex};
    return session_ready && has_frame;
}

void Interface::SetResolution(const Service::CAM::Resolution& resolution_) {
    resolution = resolution_;
}

void Interface::SetFlip(Service::CAM::Flip flip) {
    mirror = base_mirror ^
             (flip == Service::CAM::Flip::Horizontal || flip == Service::CAM::Flip::Reverse);
    invert =
        base_invert ^ (flip == Service::CAM::Flip::Vertical || flip == Service::CAM::Flip::Reverse);
}

void Interface::SetFormat(Service::CAM::OutputFormat format_) {
    format = format_;
}

std::unique_ptr<CameraInterface> Factory::Create(const std::string& config,
                                               const Service::CAM::Flip& flip) {
    return std::make_unique<Interface>(config, flip);
}

#undef YUV

} // namespace Camera::Ohos
