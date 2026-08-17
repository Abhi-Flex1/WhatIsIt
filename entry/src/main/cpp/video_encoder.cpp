// H.264 video encoder wrapper (OH_VideoEncoder, surface mode).
//
// Surface mode: camera preview renders into the encoder's OHNativeWindow,
// the encoder produces H.264 Annex-B AUs via OH_AVCodecOnNewOutputBuffer.
#include "video_encoder.h"
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <native_window/external_window.h>
#include <hilog/log.h>
#include <cstring>

#undef LOG_TAG
#define LOG_TAG "CallMediaEnc"
#define LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))
#define LOGI(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))

VideoEncoder::VideoEncoder() : codec_(nullptr), surface_(nullptr), width_(640), height_(480), bitrate_(1000000) {}

VideoEncoder::~VideoEncoder() { Release(); }

static void OnEncError(OH_AVCodec *codec, int32_t errorCode, void *userData) {
    (void)codec; (void)errorCode; (void)userData;
    LOGE("encoder error %{public}d", errorCode);
}

static void OnEncStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData) {
    (void)codec; (void)format; (void)userData;
}

static void OnEncNeedInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    // Surface mode: no input-buffer callback needed.
    (void)codec; (void)index; (void)buffer; (void)userData;
}

static void OnEncNewOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    auto *self = static_cast<VideoEncoder *>(userData);
    OH_AVCodecBufferAttr attr;
    OH_AVBuffer_GetBufferAttr(buffer, &attr);
    if (attr.size > 0) {
        uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
        if (addr && self->outputCb_) {
            self->outputCb_(addr, attr.size);  // Annex-B AU → WS → server
        }
    }
    OH_VideoEncoder_FreeOutputBuffer(codec, index);
}

std::string VideoEncoder::Init(int32_t width, int32_t height, int32_t bitrate) {
    width_ = width; height_ = height; bitrate_ = bitrate;

    OH_AVCapability *cap = OH_AVCodec_GetCapability(OH_AVCODEC_MIMETYPE_VIDEO_AVC, true);
    if (cap == nullptr) {
        LOGE("no H.264 encoder capability");
        return "";
    }
    const char *name = OH_AVCapability_GetName(cap);
    codec_ = OH_VideoEncoder_CreateByName(name);
    if (codec_ == nullptr) {
        LOGE("create encoder failed");
        return "";
    }

    OH_AVCodecCallback cb = {OnEncError, OnEncStreamChanged, OnEncNeedInput, OnEncNewOutput};
    if (OH_VideoEncoder_RegisterCallback(codec_, cb, this) != AV_ERR_OK) {
        LOGE("register callback failed");
        return "";
    }

    OH_AVFormat *fmt = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_WIDTH, width_);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_HEIGHT, height_);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_RANGE_FLAG, 0);
    OH_AVFormat_SetDoubleValue(fmt, OH_MD_KEY_FRAME_RATE, 30.0);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_I_FRAME_INTERVAL, 1000);
    OH_AVFormat_SetLongValue(fmt, OH_MD_KEY_BITRATE, bitrate_);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, OH_BitrateMode::BITRATE_MODE_VBR);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PROFILE, OH_AVCProfile::AVC_PROFILE_HIGH);
    if (OH_VideoEncoder_Configure(codec_, fmt) != AV_ERR_OK) {
        LOGE("configure encoder failed");
        OH_AVFormat_Destroy(fmt);
        return "";
    }
    OH_AVFormat_Destroy(fmt);

    OHNativeWindow *window = nullptr;
    if (OH_VideoEncoder_GetSurface(codec_, &window) != AV_ERR_OK || window == nullptr) {
        LOGE("get encoder surface failed");
        return "";
    }
    surface_ = window;
    // Surface id for the camera preview XComponent to render into.
    uint64_t id = 0;
    OH_NativeWindow_GetSurfaceId(window, &id);
    return std::to_string(id);
}

void VideoEncoder::Start() {
    if (codec_ && OH_VideoEncoder_Prepare(codec_) == AV_ERR_OK) {
        OH_VideoEncoder_Start(codec_);
        LOGI("encoder started %{public}dx%{public}d", width_, height_);
    }
}

void VideoEncoder::Stop() {
    if (codec_) {
        OH_VideoEncoder_Stop(codec_);
        OH_VideoEncoder_Flush(codec_);
    }
}

void VideoEncoder::Release() {
    if (surface_) {
        OH_NativeWindow_DestroyNativeWindow(surface_);
        surface_ = nullptr;
    }
    if (codec_) {
        OH_VideoEncoder_Destroy(codec_);
        codec_ = nullptr;
    }
}

void VideoEncoder::SetOutputCallback(EncodedFrameCallback cb) { outputCb_ = cb; }
