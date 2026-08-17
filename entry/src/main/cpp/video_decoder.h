// H.264 video decoder wrapper (OH_VideoDecoder, surface mode).
#pragma once
#include <string>
#include <cstdint>
#include <cstddef>
#include <queue>
#include <vector>

struct OH_AVCodec;
struct OH_AVBuffer;
struct NativeWindow;

class VideoDecoder {
public:
    VideoDecoder();
    ~VideoDecoder();
    // surfaceId: the XComponent surface id the decoded frames render to.
    bool Init(uint64_t surfaceId);
    void Start();
    void Stop();
    void Release();
    // Queue a peer AU (from WS) for the decoder.
    void PushFrame(const uint8_t *data, size_t len);
    // Called from the input-buffer callback to fill the next pending AU.
    void FillInput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer);
private:
    OH_AVCodec *codec_;
    NativeWindow *surface_;
    std::queue<std::vector<uint8_t>> queue_;
};
