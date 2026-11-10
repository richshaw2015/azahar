// Copyright 2020-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include <atomic>
#include <fstream>
#include <mutex>
#include <libyuv.h>
#include <multimedia/image_framework/image/image_source_native.h>
#include <multimedia/image_framework/image/pixelmap_native.h>
#include "camera/ohos_still_image_camera.h"
#include "common/logging/log.h"
#include "core/frontend/camera/blank_camera.h"

namespace Camera::OhosStillImage {

namespace {

std::atomic<bool> still_image_pick_pending{false};
std::mutex last_path_mutex;
std::string last_path; // Session-cached image path, mirrors Android Factory::last_path

} // namespace

void NotifyStillImagePickNeeded() {
    still_image_pick_pending.store(true);
}

bool ConsumeStillImagePickRequest() {
    return still_image_pick_pending.exchange(false);
}

void SetStillImagePath(const std::string& path) {
    std::lock_guard lock{last_path_mutex};
    last_path = path;
}

// Decodes an image file into tightly packed RGBA_8888 pixels via OHOS ImageKit.
static bool DecodeImageFile(const std::string& path, std::vector<u8>& pixels, uint32_t& width,
                            uint32_t& height) {
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        LOG_ERROR(Service_CAM, "Could not open image file \"{}\"", path);
        return false;
    }
    const std::streamsize size = file.tellg();
    if (size <= 0) {
        return false;
    }
    file.seekg(0, std::ios::beg);
    std::vector<u8> data(static_cast<size_t>(size));
    if (!file.read(reinterpret_cast<char*>(data.data()), size)) {
        return false;
    }

    OH_ImageSourceNative* source = nullptr;
    if (OH_ImageSourceNative_CreateFromData(data.data(), data.size(), &source) != IMAGE_SUCCESS ||
        source == nullptr) {
        LOG_ERROR(Service_CAM, "Could not create image source for \"{}\"", path);
        return false;
    }

    OH_PixelmapNative* pixelmap = nullptr;
    OH_DecodingOptions* options = nullptr;
    bool ok = false;
    do {
        if (OH_DecodingOptions_Create(&options) != IMAGE_SUCCESS) {
            break;
        }
        if (OH_DecodingOptions_SetPixelFormat(options, PIXEL_FORMAT_RGBA_8888) != IMAGE_SUCCESS) {
            break;
        }
        if (OH_ImageSourceNative_CreatePixelmap(source, options, &pixelmap) != IMAGE_SUCCESS ||
            pixelmap == nullptr) {
            break;
        }

        OH_Pixelmap_ImageInfo* info = nullptr;
        uint32_t w = 0;
        uint32_t h = 0;
        if (OH_PixelmapImageInfo_Create(&info) == IMAGE_SUCCESS) {
            OH_PixelmapImageInfo_GetWidth(info, &w);
            OH_PixelmapImageInfo_GetHeight(info, &h);
            OH_PixelmapImageInfo_Release(info);
        }
        if (w == 0 || h == 0) {
            break;
        }

        const size_t buffer_size = static_cast<size_t>(w) * h * 4;
        size_t read_size = buffer_size;
        std::vector<u8> decoded(buffer_size);
        if (OH_PixelmapNative_ReadPixels(pixelmap, decoded.data(), &read_size) != IMAGE_SUCCESS ||
            read_size < buffer_size) {
            break;
        }
        pixels = std::move(decoded);
        width = w;
        height = h;
        ok = true;
    } while (false);

    if (pixelmap != nullptr) {
        OH_PixelmapNative_Release(pixelmap);
    }
    if (options != nullptr) {
        OH_DecodingOptions_Release(options);
    }
    OH_ImageSourceNative_Release(source);

    if (!ok) {
        LOG_ERROR(Service_CAM, "Could not decode image file \"{}\"", path);
    }
    return ok;
}

Interface::Interface(std::string path_, const Service::CAM::Flip& flip)
    : path(std::move(path_)) {
    mirror = base_mirror =
        flip == Service::CAM::Flip::Horizontal || flip == Service::CAM::Flip::Reverse;
    invert = base_invert =
        flip == Service::CAM::Flip::Vertical || flip == Service::CAM::Flip::Reverse;
}

Interface::~Interface() {
    std::lock_guard lock{last_path_mutex};
    last_path.clear();
}

void Interface::StartCapture() {
    std::vector<u8> rgba;
    uint32_t src_width = 0;
    uint32_t src_height = 0;
    if (!DecodeImageFile(path, rgba, src_width, src_height)) {
        opened = false;
        return;
    }
    if (resolution.width == 0 || resolution.height == 0) {
        LOG_ERROR(Service_CAM, "Camera resolution was not set before capture");
        opened = false;
        return;
    }

    // OHOS RGBA_8888 pixel memory is R,G,B,A which libyuv addresses as ABGR.
    const int src_stride = static_cast<int>(src_width) * 4;
    std::vector<u8> argb(rgba.size());
    libyuv::ABGRToARGB(rgba.data(), src_stride, argb.data(), src_stride,
                     static_cast<int>(src_width), static_cast<int>(src_height));

    const int dst_width = resolution.width;
    const int dst_height = resolution.height;
    const int dst_stride = dst_width * 4;
    std::vector<u8> scaled(static_cast<size_t>(dst_stride) * dst_height);
    libyuv::ARGBScale(argb.data(), src_stride, static_cast<int>(src_width),
                      static_cast<int>(src_height), scaled.data(), dst_stride, dst_width,
                      dst_height, libyuv::kFilterBilinear);

    if (mirror) {
        std::vector<u8> mirrored(scaled.size());
        libyuv::ARGBMirror(scaled.data(), dst_stride, mirrored.data(), dst_stride, dst_width,
                           dst_height);
        scaled.swap(mirrored);
    }

    image.resize(static_cast<size_t>(dst_width) * dst_height);
    if (format == Service::CAM::OutputFormat::RGB565) {
        libyuv::ARGBToRGB565(scaled.data(), dst_stride, reinterpret_cast<u8*>(image.data()),
                             dst_width * 2, dst_width, invert ? -dst_height : dst_height);
    } else {
        libyuv::ARGBToYUY2(scaled.data(), dst_stride, reinterpret_cast<u8*>(image.data()),
                           dst_width * 2, dst_width, invert ? -dst_height : dst_height);
    }
    opened = true;
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

std::vector<u16> Interface::ReceiveFrame() {
    return image;
}

bool Interface::IsPreviewAvailable() {
    return opened;
}

std::unique_ptr<CameraInterface> Factory::Create(const std::string& /*config*/,
                                               const Service::CAM::Flip& flip) {
    {
        std::lock_guard lock{last_path_mutex};
        if (!last_path.empty()) {
            return std::make_unique<Interface>(last_path, flip);
        }
    }
    // Same as Android: the image path is never persisted — ask the frontend to
    // open the file picker whenever a new still image camera has no cached path,
    // and fall back to a blank feed until the camera is reloaded.
    NotifyStillImagePickNeeded();
    return std::make_unique<BlankCamera>();
}

} // namespace Camera::OhosStillImage
