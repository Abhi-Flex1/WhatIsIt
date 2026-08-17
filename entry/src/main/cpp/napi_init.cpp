// Native call media module — NAPI surface for the ArkTS call service.
//
// Exposes the H.264 encode/decode pipeline. The ArkTS side drives it:
//   - initEncoder(width, height, bitrate) -> surfaceId (camera preview feeds it)
//   - initDecoder() -> surfaceId (peer video renders here)
//   - start() / stop() / release()
//   - onEncodedFrame(cb)  — callback with each Annex-B AU (to WS → server)
//   - pushDecodedFrame(bytes) — feed a peer AU to the decoder
#include "napi/native_api.h"
#include "hilog/log.h"
#include <cstring>

#include "video_encoder.h"
#include "video_decoder.h"

#undef LOG_TAG
#define LOG_TAG "CallMedia"
#define LOGI(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))
#define LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))

static VideoEncoder *g_encoder = nullptr;
static VideoDecoder *g_decoder = nullptr;

static napi_value InitEncoder(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t width = 640, height = 480, bitrate = 1000000;
    napi_get_value_int32(env, args[0], &width);
    napi_get_value_int32(env, args[1], &height);
    napi_get_value_int32(env, args[2], &bitrate);
    if (g_encoder == nullptr) {
        g_encoder = new VideoEncoder();
    }
    std::string surfaceId = g_encoder->Init(width, height, bitrate);
    napi_value result;
    napi_create_string_utf8(env, surfaceId.c_str(), surfaceId.size(), &result);
    return result;
}

static napi_value StartEncoder(napi_env env, napi_callback_info info) {
    if (g_encoder) g_encoder->Start();
    return nullptr;
}

static napi_value StopEncoder(napi_env env, napi_callback_info info) {
    if (g_encoder) g_encoder->Stop();
    return nullptr;
}

static napi_value ReleaseEncoder(napi_env env, napi_callback_info info) {
    if (g_encoder) { delete g_encoder; g_encoder = nullptr; }
    return nullptr;
}

static napi_value InitDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    uint64_t surfaceId = 0;
    if (argc >= 1) {
        int32_t id = 0;
        napi_get_value_int32(env, args[0], &id);
        surfaceId = static_cast<uint64_t>(id);
    }
    if (g_decoder == nullptr) {
        g_decoder = new VideoDecoder();
    }
    bool ok = g_decoder->Init(surfaceId);
    napi_value result;
    napi_get_boolean(env, ok, &result);
    return result;
}

static napi_value StartDecoder(napi_env env, napi_callback_info info) {
    if (g_decoder) g_decoder->Start();
    return nullptr;
}

static napi_value StopDecoder(napi_env env, napi_callback_info info) {
    if (g_decoder) g_decoder->Stop();
    return nullptr;
}

static napi_value ReleaseDecoder(napi_env env, napi_callback_info info) {
    if (g_decoder) { delete g_decoder; g_decoder = nullptr; }
    return nullptr;
}

static napi_value PushDecodedFrame(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (g_decoder == nullptr) return nullptr;
    void *data = nullptr;
    size_t len = 0;
    napi_get_arraybuffer_info(env, args[0], &data, &len);
    g_decoder->PushFrame(static_cast<uint8_t *>(data), len);
    return nullptr;
}

// Called by the encoder on each produced AU → forwards to the JS callback.
static napi_env g_cb_env = nullptr;
static napi_ref g_encoded_cb = nullptr;

void OnEncodedFrame(const uint8_t *data, size_t len) {
    if (g_cb_env == nullptr || g_encoded_cb == nullptr) return;
    napi_value cb;
    napi_get_reference_value(g_cb_env, g_encoded_cb, &cb);
    napi_value arg;
    void *buf = nullptr;
    napi_create_arraybuffer(g_cb_env, len, &buf, &arg);
    memcpy(buf, data, len);
    napi_value global;
    napi_get_global(g_cb_env, &global);
    napi_value result;
    napi_call_function(g_cb_env, global, cb, 1, &arg, &result);
}

static napi_value SetEncodedCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    g_cb_env = env;
    napi_create_reference(env, args[0], 1, &g_encoded_cb);
    if (g_encoder) g_encoder->SetOutputCallback(OnEncodedFrame);
    return nullptr;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"initEncoder", nullptr, InitEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startEncoder", nullptr, StartEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopEncoder", nullptr, StopEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseEncoder", nullptr, ReleaseEncoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initDecoder", nullptr, InitDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startDecoder", nullptr, StartDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopDecoder", nullptr, StopDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseDecoder", nullptr, ReleaseDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushDecodedFrame", nullptr, PushDecodedFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEncodedCallback", nullptr, SetEncodedCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "call_media",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterCallMediaModule(void) {
    napi_module_register(&demoModule);
}
