// NAPI bridge for the embedded WhatsApp engine (wa_engine).
//
// Exposes the Rust whatsapp-rust core (compiled as libwa_engine.so/a) to
// ArkTS as a NAPI module: `import waEngine from 'libwa_engine.so'`.
//
// The Rust side exports a C ABI (engine/src/cabi.rs):
//   wa_engine_start(dataDir), wa_engine_stop(),
//   wa_engine_status(), wa_engine_chats(), wa_engine_messages(chat, limit),
//   wa_engine_start_pairing(), wa_engine_free_string(s),
//   wa_engine_set_event_cb(cb)
//
// Events (qr/linked/message/receipt/chats/logged_out/pair_code) arrive on the
// engine thread; we marshal them to a napi_ref callback the ArkTS side
// registers, and ArkTS dispatches onto the UI thread itself.
#include "napi/native_api.h"
#include "hilog/log.h"
#include <cstring>
#include <string>

// Declared in engine/src/cabi.rs (cdylib exports). Linked from
// libwa_engine.a (aarch64/x86_64 ohos) or the .so.
extern "C" {
void wa_engine_set_event_cb(void (*cb)(const char *type, const char *json));
int wa_engine_start(const char *data_dir);
int wa_engine_stop();
char *wa_engine_status();
char *wa_engine_chats();
char *wa_engine_messages(const char *chat, int limit);
void wa_engine_start_pairing();
int wa_engine_pair_code(const char *phone);
int wa_engine_logout();
void wa_engine_free_string(char *s);
}

#undef LOG_TAG
#define LOG_TAG "WaEngine"
#define LOGI(...) ((void)OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))
#define LOGE(...) ((void)OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))

// ArkTS event callback (a napi_ref to a JS function). Invoked from the engine
// thread — the ArkTS side must hop to the UI thread (e.g. via postTask).
static napi_env g_env = nullptr;
static napi_ref g_event_cb = nullptr;

/// Called by the Rust engine on each event (engine thread).
static void OnEngineEvent(const char *type, const char *json) {
    if (g_env == nullptr || g_event_cb == nullptr) return;
    napi_handle_scope scope;
    napi_open_handle_scope(g_env, &scope);
    napi_value cb;
    if (napi_get_reference_value(g_env, g_event_cb, &cb) == napi_ok) {
        napi_value args[2];
        napi_create_string_utf8(g_env, type, strlen(type), &args[0]);
        napi_create_string_utf8(g_env, json, strlen(json), &args[1]);
        napi_value global;
        napi_get_global(g_env, &global);
        napi_value result;
        napi_call_function(g_env, global, cb, 2, args, &result);
    }
    napi_close_handle_scope(g_env, scope);
}

static char *dup_str(const std::string &s) {
    char *out = (char *)malloc(s.size() + 1);
    if (out) {
        memcpy(out, s.c_str(), s.size() + 1);
    }
    return out;
}

// ---- NAPI entry points ----

static napi_value NapiStart(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string dir;
    if (argc >= 1) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        if (len > 0) {
            char *buf = (char *)malloc(len + 1);
            napi_get_value_string_utf8(env, args[0], buf, len + 1, &len);
            dir = buf;
            free(buf);
        }
    }
    int rc = wa_engine_start(dir.c_str());
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value NapiStop(napi_env env, napi_callback_info info) {
    int rc = wa_engine_stop();
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value NapiStatus(napi_env env, napi_callback_info info) {
    char *s = wa_engine_status();
    napi_value result;
    napi_create_string_utf8(env, s ? s : "{}", s ? strlen(s) : 2, &result);
    if (s) wa_engine_free_string(s);
    return result;
}

static napi_value NapiChats(napi_env env, napi_callback_info info) {
    char *s = wa_engine_chats();
    napi_value result;
    napi_create_string_utf8(env, s ? s : "[]", s ? strlen(s) : 2, &result);
    if (s) wa_engine_free_string(s);
    return result;
}

static napi_value NapiMessages(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string chat;
    if (argc >= 1) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        if (len > 0) {
            char *buf = (char *)malloc(len + 1);
            napi_get_value_string_utf8(env, args[0], buf, len + 1, &len);
            chat = buf;
            free(buf);
        }
    }
    int32_t limit = 200;
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &limit);
    }
    char *s = wa_engine_messages(chat.c_str(), limit);
    napi_value result;
    napi_create_string_utf8(env, s ? s : "[]", s ? strlen(s) : 2, &result);
    if (s) wa_engine_free_string(s);
    return result;
}

static napi_value NapiStartPairing(napi_env env, napi_callback_info info) {
    wa_engine_start_pairing();
    return nullptr;
}

static napi_value NapiPairCode(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string phone;
    if (argc >= 1) {
        size_t len = 0;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        if (len > 0) {
            char *buf = (char *)malloc(len + 1);
            napi_get_value_string_utf8(env, args[0], buf, len + 1, &len);
            phone = buf;
            free(buf);
        }
    }
    int rc = wa_engine_pair_code(phone.c_str());
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value NapiLogout(napi_env env, napi_callback_info info) {
    int rc = wa_engine_logout();
    napi_value result;
    napi_create_int32(env, rc, &result);
    return result;
}

static napi_value NapiSetEventCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1 && args[0] != nullptr) {
        // Replace any prior callback.
        if (g_event_cb != nullptr) {
            napi_delete_reference(env, g_event_cb);
        }
        g_env = env;
        napi_create_reference(env, args[0], 1, &g_event_cb);
        wa_engine_set_event_cb(OnEngineEvent);
    }
    return nullptr;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"start", nullptr, NapiStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, NapiStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, NapiStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"chats", nullptr, NapiChats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"messages", nullptr, NapiMessages, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startPairing", nullptr, NapiStartPairing, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pairCode", nullptr, NapiPairCode, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"logout", nullptr, NapiLogout, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setEventCallback", nullptr, NapiSetEventCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module waEngineModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "wa_engine",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterWaEngineModule(void) {
    napi_module_register(&waEngineModule);
}
