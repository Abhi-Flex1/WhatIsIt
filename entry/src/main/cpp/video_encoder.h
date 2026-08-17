// H.264 video decoder wrapper (OH_VideoDecoder, surface mode).
//
// Peer AUs pushed from the app (over WS) are decoded to a surface the
// native call UI renders (XComponent).
#pragma once
#include <string>
#include <cstdint>
#include <cstddef>
#include <functional>

using EncodedFrameCallback = std::function<void(const uint8_t *, size_t)>;

struct OH_AVCodec;
struct NativeWindow;

class VideoEncoder {
public:
    VideoEncoder();
    ~VideoEncoder();
    std::string Init(int32_t width, int32_t height, int32_t bitrate);
    void Start();
    void Stop();
    void Release();
    void SetOutputCallback(EncodedFrameCallback cb);
    // Public so the C callback (OnEncNewOutput) can invoke it.
    EncodedFrameCallback outputCb_;
private:
    OH_AVCodec *codec_;
    NativeWindow *surface_;
    int32_t width_;
    int32_t height_;
    int32_t bitrate_;
};
