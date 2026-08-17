// H.264 video decoder wrapper (OH_VideoDecoder, surface mode).
#include "video_decoder.h"
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <native_window/external_window.h>
#include <hilog/log.h>
#include <cstring>

#undef LOG_TAG
#define LOG_TAG "CallMediaDec"
#define LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))
#define LOGI(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))

VideoDecoder::VideoDecoder() : codec_(nullptr), surface_(nullptr) {}
VideoDecoder::~VideoDecoder() { Release(); }

static void OnDecError(OH_AVCodec *codec, int32_t errorCode, void *userData) {
    (void)codec; (void)userData;
    LOGE("decoder error %{public}d", errorCode);
}

static void OnDecStreamChanged(OH_AVCodec *codec, OH_AVFormat *format, void *userData) {
    (void)codec; (void)format; (void)userData;
}

static void OnDecNeedInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    auto *self = static_cast<VideoDecoder *>(userData);
    // Enqueue the next pending AU (queued from PushFrame) into this input.
    self->FillInput(codec, index, buffer);
}

static void OnDecNewOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *userData) {
    (void)userData;
    // The frame is rendered to the output surface automatically.
    OH_VideoDecoder_FreeOutputBuffer(codec, index);
}

bool VideoDecoder::Init(uint64_t surfaceId) {
    OH_AVCapability *cap = OH_AVCodec_GetCapability(OH_AVCODEC_MIMETYPE_VIDEO_AVC, false);
    if (cap == nullptr) {
        LOGE("no H.264 decoder capability");
        return false;
    }
    const char *name = OH_AVCapability_GetName(cap);
    codec_ = OH_VideoDecoder_CreateByName(name);
    if (codec_ == nullptr) {
        LOGE("create decoder failed");
        return false;
    }

    OH_AVCodecCallback cb = {OnDecError, OnDecStreamChanged, OnDecNeedInput, OnDecNewOutput};
    if (OH_VideoDecoder_RegisterCallback(codec_, cb, this) != AV_ERR_OK) {
        LOGE("register decoder callback failed");
        return false;
    }

    // Width/height are learned from the stream (SPS); the surface carries them.
    OH_AVFormat *fmt = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_WIDTH, 640);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_HEIGHT, 480);
    OH_AVFormat_SetIntValue(fmt, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    if (OH_VideoDecoder_Configure(codec_, fmt) != AV_ERR_OK) {
        LOGE("configure decoder failed");
        OH_AVFormat_Destroy(fmt);
        return false;
    }
    OH_AVFormat_Destroy(fmt);

    // Wrap the app's XComponent surface id into an OHNativeWindow for output.
    if (OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &surface_) != 0 || surface_ == nullptr) {
        LOGE("wrap decoder surface failed (id=%{public}llu)", (unsigned long long)surfaceId);
        return false;
    }
    if (OH_VideoDecoder_SetSurface(codec_, surface_) != AV_ERR_OK) {
        LOGE("set decoder surface failed");
        return false;
    }
    return true;
}

void VideoDecoder::Start() {
    if (codec_ && OH_VideoDecoder_Prepare(codec_) == AV_ERR_OK) {
        OH_VideoDecoder_Start(codec_);
        LOGI("decoder started");
    }
}

void VideoDecoder::Stop() {
    if (codec_) {
        OH_VideoDecoder_Stop(codec_);
        OH_VideoDecoder_Flush(codec_);
    }
}

void VideoDecoder::Release() {
    if (surface_) {
        OH_NativeWindow_DestroyNativeWindow(surface_);
        surface_ = nullptr;
    }
    if (codec_) {
        OH_VideoDecoder_Destroy(codec_);
        codec_ = nullptr;
    }
}

void VideoDecoder::PushFrame(const uint8_t *data, size_t len) {
    std::vector<uint8_t> au(data, data + len);
    queue_.push(std::move(au));
}

void VideoDecoder::FillInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer) {
    if (queue_.empty()) return;
    auto au = std::move(queue_.front());
    queue_.pop();
    uint8_t *addr = OH_AVBuffer_GetAddr(buffer);
    size_t cap = OH_AVBuffer_GetCapacity(buffer);
    if (addr == nullptr || au.size() > cap) {
        LOGE("input buffer too small or null");
        return;
    }
    memcpy(addr, au.data(), au.size());
    OH_AVCodecBufferAttr attr{};
    attr.size = au.size();
    attr.offset = 0;
    attr.pts = 0;
    attr.flags = 0;
    OH_AVBuffer_SetBufferAttr(buffer, &attr);
    OH_VideoDecoder_PushInputBuffer(codec, index);
}
