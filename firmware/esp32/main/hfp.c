#include "hfp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ancs_proto.h" // json_escape
#include "esp_bt_device.h"
#include "esp_gap_bt_api.h"
#include "esp_hf_client_api.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "serial_link.h"

#define NVS_NS "nb_hfp"
#define RECONNECT_MIN_US (5LL * 1000 * 1000)
#define RECONNECT_MAX_US (60LL * 1000 * 1000)

static SemaphoreHandle_t s_lock;
#define LOCK() xSemaphoreTakeRecursive(s_lock, portMAX_DELAY)
#define UNLOCK() xSemaphoreGiveRecursive(s_lock)

static hfp_pairing_open_fn s_pairing_open;
static esp_hf_client_connection_state_t s_conn = ESP_HF_CLIENT_CONNECTION_STATE_DISCONNECTED;
static esp_hf_client_audio_state_t s_audio = ESP_HF_CLIENT_AUDIO_STATE_DISCONNECTED;
static esp_bd_addr_t s_peer;
static bool s_has_peer;
static int s_call, s_setup, s_held; // CIND：通话中、呼叫建立阶段（1 来电 2 呼出 3 对方振铃）、保持
static char s_clip[40];             // 来电号码
static bool s_audio_to_pc;          // 通话声音走电脑（第二阶段）；否则留在手机上
static bool s_user_disconnected;    // 电脑要求断开：不自动回连
static int64_t s_next_reconnect;
static int64_t s_backoff = RECONNECT_MIN_US;
static bool s_discoverable;
static int s_battery = -1, s_signal = -1;
static char s_operator[32];
static int64_t s_grace_until; // 刚配对完的一小段时间里允许手机补做一次配对（iPhone 会连着做两次）

static void fmt(const uint8_t *b, char *out) {
    sprintf(out, "%02x:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4], b[5]);
}

static bool parse(const char *s, esp_bd_addr_t out) {
    unsigned v[6];
    if (sscanf(s, "%2x:%2x:%2x:%2x:%2x:%2x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6) return false;
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)v[i];
    return true;
}

// ---- NVS：上次连接的手机、手机名字 ----
static void key_of(const uint8_t *bda, char *key) {
    sprintf(key, "%02x%02x%02x%02x%02x%02x", bda[0], bda[1], bda[2], bda[3], bda[4], bda[5]);
}

static void nv_set_str(const char *key, const char *val) {
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READWRITE, &h) != ESP_OK) return;
    if (val) nvs_set_str(h, key, val);
    else nvs_erase_key(h, key);
    nvs_commit(h);
    nvs_close(h);
}

static bool nv_get_str(const char *key, char *out, size_t cap) {
    out[0] = 0;
    nvs_handle_t h;
    if (nvs_open(NVS_NS, NVS_READONLY, &h) != ESP_OK) return false;
    size_t len = cap;
    bool ok = nvs_get_str(h, key, out, &len) == ESP_OK;
    nvs_close(h);
    if (!ok) out[0] = 0;
    return ok;
}

static bool last_peer(esp_bd_addr_t out) {
    char s[18];
    return nv_get_str("last", s, sizeof s) && parse(s, out);
}

static bool is_bonded(const uint8_t *bda);

static bool pref_peer(esp_bd_addr_t out) {
    char s[18];
    return nv_get_str("pref", s, sizeof s) && parse(s, out);
}

// 回连顺序：通话优先手机 → 上次连接的手机 → 其他配对过的手机。每次尝试下一台，一轮都不在才拉长间隔。
static int s_try_index;
static esp_bd_addr_t s_switch_to; // 手动切换：断开当前手机后连这台
static bool s_switch_pending;

static int candidates(esp_bd_addr_t *out, int cap) {
    int n = 0;
    esp_bd_addr_t a;
    if (pref_peer(a) && is_bonded(a)) memcpy(out[n++], a, 6);
    if (last_peer(a) && is_bonded(a) && (n == 0 || memcmp(out[0], a, 6) != 0)) memcpy(out[n++], a, 6);
    int m = esp_bt_gap_get_bond_device_num();
    if (m > 0) {
        esp_bd_addr_t *list = calloc(m, sizeof(esp_bd_addr_t));
        if (list) {
            esp_bt_gap_get_bond_device_list(&m, list);
            for (int i = 0; i < m && n < cap; i++) {
                bool dup = false;
                for (int j = 0; j < n; j++) dup |= memcmp(out[j], list[i], 6) == 0;
                if (!dup) memcpy(out[n++], list[i], 6);
            }
            free(list);
        }
    }
    return n;
}

static bool is_bonded(const uint8_t *bda) {
    int n = esp_bt_gap_get_bond_device_num();
    if (n <= 0) return false;
    esp_bd_addr_t *list = calloc(n, sizeof(esp_bd_addr_t));
    if (!list) return false;
    esp_bt_gap_get_bond_device_list(&n, list);
    bool found = false;
    for (int i = 0; i < n; i++) found |= memcmp(list[i], bda, 6) == 0;
    free(list);
    return found;
}

// ---- 事件输出 ----
static const char *conn_str(void) {
    switch (s_conn) {
    case ESP_HF_CLIENT_CONNECTION_STATE_CONNECTING: return "connecting";
    case ESP_HF_CLIENT_CONNECTION_STATE_CONNECTED: return "connecting";
    case ESP_HF_CLIENT_CONNECTION_STATE_SLC_CONNECTED: return "connected";
    case ESP_HF_CLIENT_CONNECTION_STATE_DISCONNECTING: return "disconnecting";
    default: return "disconnected";
    }
}

static const char *audio_str(void) {
    switch (s_audio) {
    case ESP_HF_CLIENT_AUDIO_STATE_CONNECTING: return "connecting";
    case ESP_HF_CLIENT_AUDIO_STATE_CONNECTED: return "cvsd";
    case ESP_HF_CLIENT_AUDIO_STATE_CONNECTED_MSBC: return "msbc";
    default: return "off";
    }
}

static void emit_hfp(void) {
    char peer[18] = "", name[64] = "", esc[140], key[13], op[70];
    if (s_has_peer) {
        fmt(s_peer, peer);
        key_of(s_peer, key);
        nv_get_str(key, name, sizeof name);
    }
    json_escape(name, esc, sizeof esc);
    json_escape(s_operator, op, sizeof op);
    serial_eventf("{\"t\":\"hfp\",\"state\":\"%s\",\"peer\":\"%s\",\"name\":\"%s\",\"audio\":\"%s\",\"audioTo\":\"%s\","
                  "\"battery\":%d,\"signal\":%d,\"operator\":\"%s\",\"discoverable\":%s}",
                  conn_str(), peer, esc, audio_str(), s_audio_to_pc ? "pc" : "phone", s_battery, s_signal, op,
                  s_discoverable ? "true" : "false");
}

static void emit_call(void) {
    char num[90];
    json_escape(s_clip, num, sizeof num);
    // state：idle 空闲 / incoming 来电 / dialing 呼出 / alerting 对方振铃 / active 通话中
    const char *st = s_setup == 1 ? "incoming" : s_setup == 2 ? "dialing" : s_setup == 3 ? "alerting"
                     : s_call ? "active" : "idle";
    serial_eventf("{\"t\":\"call\",\"state\":\"%s\",\"number\":\"%s\",\"call\":%d,\"setup\":%d,\"held\":%d}", st, num,
                  s_call, s_setup, s_held);
}

static void emit_phones(void) {
    int n = esp_bt_gap_get_bond_device_num();
    if (n < 0) n = 0;
    esp_bd_addr_t *list = n ? calloc(n, sizeof(esp_bd_addr_t)) : NULL;
    if (n && !list) return;
    if (n) esp_bt_gap_get_bond_device_list(&n, list);
    static char buf[2048];
    size_t o = snprintf(buf, sizeof buf, "{\"t\":\"phones\",\"list\":[");
    for (int i = 0; i < n && o < sizeof buf - 200; i++) {
        char addr[18], name[64], esc[140], key[13];
        fmt(list[i], addr);
        key_of(list[i], key);
        nv_get_str(key, name, sizeof name);
        json_escape(name, esc, sizeof esc);
        bool conn = s_has_peer && memcmp(list[i], s_peer, 6) == 0 &&
                    s_conn == ESP_HF_CLIENT_CONNECTION_STATE_SLC_CONNECTED;
        esp_bd_addr_t pref;
        bool preferred = pref_peer(pref) && memcmp(pref, list[i], 6) == 0;
        o += snprintf(buf + o, sizeof buf - o, "%s{\"addr\":\"%s\",\"name\":\"%s\",\"connected\":%s,\"preferred\":%s}",
                      i ? "," : "", addr, esc, conn ? "true" : "false", preferred ? "true" : "false");
    }
    snprintf(buf + o, sizeof buf - o, "]}");
    free(list);
    serial_eventf("%s", buf);
}

void hfp_emit_all(void) {
    if (!s_lock) return;
    LOCK();
    emit_hfp();
    emit_call();
    emit_phones();
    UNLOCK();
}

// ---- 可被发现：配对窗口打开或还没有配对过手机时 ----
static void update_scan_mode(void) {
    bool disc = s_pairing_open() || esp_bt_gap_get_bond_device_num() <= 0;
    if (disc == s_discoverable) return;
    s_discoverable = disc;
    esp_bt_gap_set_scan_mode(ESP_BT_CONNECTABLE, disc ? ESP_BT_GENERAL_DISCOVERABLE : ESP_BT_NON_DISCOVERABLE);
    emit_hfp();
}

void hfp_pairing_changed(void) {
    if (!s_lock) return;
    LOCK();
    update_scan_mode();
    UNLOCK();
}

// ---- 通话音频：手机 → ESP32 → 串口 → 电脑（扬声器），电脑麦克风 → 串口 → ESP32 → 手机 ----
// 格式：16 位小端单声道 PCM；mSBC 为 16 kHz，CVSD 为 8 kHz（audio 事件里的 audio 字段说明是哪种）。
#include "freertos/ringbuf.h"
#define MIC_RB_SIZE 6400 // 16 kHz 下约 200 ms
static RingbufHandle_t s_mic_rb;
static uint16_t s_down_seq;
static volatile bool s_streaming;

static void audio_in(const uint8_t *buf, uint32_t len) {
    if (!s_streaming || len == 0) return;
    // 每个 SCO 包直接发给电脑（mSBC 解码后 240 字节 / 7.5 ms）
    while (len > 0) {
        uint16_t n = len > 960 ? 960 : (uint16_t)len;
        serial_send_frame(FRAME_AUDIO_DOWN, s_down_seq++, buf, n);
        buf += n;
        len -= n;
    }
    // 有下行数据就说明链路在走，顺便通知协议栈去取上行（麦克风）数据
    esp_hf_client_outgoing_data_ready();
}

static uint32_t audio_out(uint8_t *buf, uint32_t len) {
    if (!s_mic_rb) return 0;
    size_t got = 0;
    uint8_t *p = xRingbufferReceiveUpTo(s_mic_rb, &got, 0, len);
    if (!p) return 0;
    if (got == len) {
        memcpy(buf, p, len);
        vRingbufferReturnItem(s_mic_rb, p);
        return len;
    }
    // 数据不够一个包：先拼上第二段（环形缓冲区回绕时会分两次取）
    memcpy(buf, p, got);
    vRingbufferReturnItem(s_mic_rb, p);
    size_t got2 = 0;
    uint8_t *p2 = xRingbufferReceiveUpTo(s_mic_rb, &got2, 0, len - got);
    if (p2) {
        memcpy(buf + got, p2, got2);
        vRingbufferReturnItem(s_mic_rb, p2);
    }
    if (got + got2 < len) memset(buf + got + got2, 0, len - got - got2);
    return len;
}

// 电脑发来的麦克风数据
static void on_frame(uint8_t type, uint16_t seq, const uint8_t *data, uint16_t len) {
    (void)seq;
    if (type != FRAME_AUDIO_UP || !s_streaming || !s_mic_rb) return;
    if (xRingbufferSend(s_mic_rb, data, len, 0) != pdTRUE) {
        // 满了（电脑发得比手机取得快）：丢掉最旧的一段再放
        size_t got = 0;
        uint8_t *old = xRingbufferReceiveUpTo(s_mic_rb, &got, 0, len);
        if (old) vRingbufferReturnItem(s_mic_rb, old);
        xRingbufferSend(s_mic_rb, data, len, 0);
    }
}

static void audio_start(void) {
    if (!s_mic_rb) s_mic_rb = xRingbufferCreate(MIC_RB_SIZE, RINGBUF_TYPE_BYTEBUF);
    s_down_seq = 0;
    s_streaming = true;
}

static void audio_stop(void) {
    s_streaming = false;
    if (s_mic_rb) {
        size_t got;
        void *p;
        while ((p = xRingbufferReceiveUpTo(s_mic_rb, &got, 0, MIC_RB_SIZE)) != NULL) vRingbufferReturnItem(s_mic_rb, p);
    }
}

// ---- GAP（经典蓝牙）----
static void gap_cb(esp_bt_gap_cb_event_t event, esp_bt_gap_cb_param_t *param) {
    LOCK();
    switch (event) {
    case ESP_BT_GAP_CFM_REQ_EVT: {
        bool ok = s_pairing_open() || esp_bt_gap_get_bond_device_num() <= 0 || esp_timer_get_time() < s_grace_until ||
                  is_bonded(param->cfm_req.bda);
        esp_bt_gap_ssp_confirm_reply(param->cfm_req.bda, ok);
        if (ok) {
            serial_eventf("{\"t\":\"pair_code\",\"code\":\"%06lu\"}", (unsigned long)param->cfm_req.num_val);
        } else {
            serial_eventf("{\"t\":\"err\",\"code\":\"pairing_closed\",\"msg\":\"有手机请求蓝牙配对，但配对窗口未打开\"}");
        }
        break;
    }
    case ESP_BT_GAP_PIN_REQ_EVT: {
        // 旧手机不支持 SSP：配对窗口打开时用 0000
        esp_bt_pin_code_t pin = {'0', '0', '0', '0'};
        bool ok = s_pairing_open() || esp_bt_gap_get_bond_device_num() <= 0 || esp_timer_get_time() < s_grace_until;
        esp_bt_gap_pin_reply(param->pin_req.bda, ok, 4, pin);
        break;
    }
    case ESP_BT_GAP_AUTH_CMPL_EVT:
        if (param->auth_cmpl.stat == ESP_BT_STATUS_SUCCESS) {
            s_grace_until = esp_timer_get_time() + 60LL * 1000 * 1000;
            char key[13], a[18];
            key_of(param->auth_cmpl.bda, key);
            // 配对后主动连接免提（有的手机配对完不会自己连）
            fmt(param->auth_cmpl.bda, a);
            nv_set_str("last", a);
            s_user_disconnected = false;
            s_backoff = RECONNECT_MIN_US;
            if (s_conn == ESP_HF_CLIENT_CONNECTION_STATE_DISCONNECTED) s_next_reconnect = esp_timer_get_time() + 3000000;
            if (param->auth_cmpl.device_name[0]) nv_set_str(key, (const char *)param->auth_cmpl.device_name);
            emit_phones();
            update_scan_mode();
        } else {
            serial_eventf("{\"t\":\"err\",\"code\":\"bt_auth\",\"msg\":\"蓝牙配对失败（%d）\"}", param->auth_cmpl.stat);
        }
        break;
    case ESP_BT_GAP_READ_REMOTE_NAME_EVT:
        if (param->read_rmt_name.stat == ESP_BT_STATUS_SUCCESS && param->read_rmt_name.rmt_name[0]) {
            char key[13];
            key_of(param->read_rmt_name.bda, key);
            nv_set_str(key, (const char *)param->read_rmt_name.rmt_name);
            emit_hfp();
            emit_phones();
        }
        break;
    case ESP_BT_GAP_REMOVE_BOND_DEV_COMPLETE_EVT:
        emit_phones();
        update_scan_mode();
        break;
    default:
        break;
    }
    UNLOCK();
}

// ---- HFP ----
static void hf_cb(esp_hf_client_cb_event_t event, esp_hf_client_cb_param_t *param) {
    LOCK();
    switch (event) {
    case ESP_HF_CLIENT_CONNECTION_STATE_EVT:
        s_conn = param->conn_stat.state;
        memcpy(s_peer, param->conn_stat.remote_bda, 6);
        s_has_peer = true;
        if (s_conn == ESP_HF_CLIENT_CONNECTION_STATE_SLC_CONNECTED) {
            char a[18];
            fmt(s_peer, a);
            nv_set_str("last", a);
            s_backoff = RECONNECT_MIN_US;
            s_user_disconnected = false;
            esp_bt_gap_read_remote_name(s_peer);
            esp_hf_client_query_current_calls();
        } else if (s_conn == ESP_HF_CLIENT_CONNECTION_STATE_DISCONNECTED) {
            s_call = s_setup = s_held = 0;
            s_clip[0] = 0;
            s_audio = ESP_HF_CLIENT_AUDIO_STATE_DISCONNECTED;
            s_next_reconnect = esp_timer_get_time() + s_backoff;
            emit_call();
        }
        emit_hfp();
        emit_phones();
        break;
    case ESP_HF_CLIENT_AUDIO_STATE_EVT:
        s_audio = param->audio_stat.state;
        if (s_audio == ESP_HF_CLIENT_AUDIO_STATE_CONNECTED || s_audio == ESP_HF_CLIENT_AUDIO_STATE_CONNECTED_MSBC) {
            esp_hf_client_register_data_callback(audio_in, audio_out);
            // 声音留在手机上：手机把通话音频切给免提时立即断开音频连接
            if (!s_audio_to_pc) esp_hf_client_disconnect_audio(s_peer);
            else audio_start();
        } else {
            audio_stop();
        }
        emit_hfp();
        break;
    case ESP_HF_CLIENT_CIND_CALL_EVT:
        s_call = param->call.status;
        if (!s_call && !s_setup) s_clip[0] = 0;
        emit_call();
        break;
    case ESP_HF_CLIENT_CIND_CALL_SETUP_EVT:
        s_setup = param->call_setup.status;
        // 有的手机（例如 iPhone）不主动发 +CLIP：查一次当前通话拿号码
        if (s_setup && !s_clip[0]) esp_hf_client_query_current_calls();
        if (!s_call && !s_setup) s_clip[0] = 0;
        emit_call();
        break;
    case ESP_HF_CLIENT_CIND_CALL_HELD_EVT:
        s_held = param->call_held.status;
        emit_call();
        break;
    case ESP_HF_CLIENT_CLIP_EVT:
        if (param->clip.number && strcmp(s_clip, param->clip.number) != 0) {
            strlcpy(s_clip, param->clip.number, sizeof s_clip);
            emit_call();
        }
        break;
    case ESP_HF_CLIENT_CLCC_EVT:
        // 当前通话列表：连上时补齐号码（例如通话中途插上 ESP32）
        if (param->clcc.number && !s_clip[0]) {
            strlcpy(s_clip, param->clcc.number, sizeof s_clip);
            emit_call();
        }
        break;
    case ESP_HF_CLIENT_CCWA_EVT: {
        char num[90];
        json_escape(param->ccwa.number ? param->ccwa.number : "", num, sizeof num);
        serial_eventf("{\"t\":\"call_waiting\",\"number\":\"%s\"}", num);
        break;
    }
    case ESP_HF_CLIENT_CIND_BATTERY_LEVEL_EVT:
        s_battery = param->battery_level.value;
        emit_hfp();
        break;
    case ESP_HF_CLIENT_CIND_SIGNAL_STRENGTH_EVT:
        s_signal = param->signal_strength.value;
        emit_hfp();
        break;
    case ESP_HF_CLIENT_COPS_CURRENT_OPERATOR_EVT:
        strlcpy(s_operator, param->cops.name ? param->cops.name : "", sizeof s_operator);
        emit_hfp();
        break;
    case ESP_HF_CLIENT_VOLUME_CONTROL_EVT:
        serial_eventf("{\"t\":\"volume\",\"target\":\"%s\",\"value\":%d}",
                      param->volume_control.type == ESP_HF_VOLUME_CONTROL_TARGET_SPK ? "speaker" : "mic",
                      param->volume_control.volume);
        break;
    case ESP_HF_CLIENT_AT_RESPONSE_EVT:
        if (param->at_response.code != ESP_HF_AT_RESPONSE_CODE_OK) {
            serial_eventf("{\"t\":\"err\",\"code\":\"at\",\"msg\":\"手机拒绝了操作（%d）\"}", param->at_response.code);
        }
        break;
    default:
        break;
    }
    UNLOCK();
}

void hfp_tick(void) {
    if (!s_lock) return;
    LOCK();
    int64_t now = esp_timer_get_time();
    if (s_conn == ESP_HF_CLIENT_CONNECTION_STATE_DISCONNECTED && !s_user_disconnected && s_next_reconnect > 0 &&
        now >= s_next_reconnect) {
        if (s_switch_pending) {
            s_switch_pending = false;
            esp_hf_client_connect(s_switch_to);
            s_next_reconnect = now + 15000000; // 给手动切换的手机 15 秒
        } else {
            esp_bd_addr_t list[8];
            int n = candidates(list, 8);
            if (n > 0) {
                if (s_try_index >= n) s_try_index = 0;
                esp_hf_client_connect(list[s_try_index]);
                s_try_index++;
                // 一轮都不在附近：逐渐拉长间隔，最长 1 分钟
                if (s_try_index >= n) {
                    s_try_index = 0;
                    s_backoff = s_backoff * 2 > RECONNECT_MAX_US ? RECONNECT_MAX_US : s_backoff * 2;
                    s_next_reconnect = now + s_backoff;
                } else {
                    s_next_reconnect = now + 8000000; // 连接一台手机最多等约 8 秒，再试下一台
                }
            } else {
                s_next_reconnect = now + s_backoff;
            }
        }
    }
    update_scan_mode();
    UNLOCK();
}

bool hfp_handle_command(const char *line) {
    if (!s_lock) return false;
    bool handled = true;
    LOCK();
    if (strcmp(line, "ANSWER") == 0) {
        esp_hf_client_answer_call();
    } else if (strcmp(line, "HANGUP") == 0) {
        // 来电时是拒接，通话中/呼出时是挂断（都是 AT+CHUP）
        esp_hf_client_reject_call();
    } else if (strncmp(line, "DIAL ", 5) == 0) {
        const char *n = line + 5;
        bool ok = *n && strlen(n) < 32;
        for (const char *p = n; *p && ok; p++) ok = strchr("0123456789+*#,", *p) != NULL;
        if (ok) esp_hf_client_dial(n);
        else serial_eventf("{\"t\":\"err\",\"code\":\"bad_number\",\"msg\":\"号码格式不对\"}");
    } else if (strcmp(line, "REDIAL") == 0) {
        esp_hf_client_dial(NULL);
    } else if (strncmp(line, "DTMF ", 5) == 0 && line[5] && strchr("0123456789*#ABCD", line[5])) {
        esp_hf_client_send_dtmf(line[5]);
    } else if (strcmp(line, "AUDIO PC") == 0 || strcmp(line, "AUDIO PHONE") == 0) {
        s_audio_to_pc = strcmp(line, "AUDIO PC") == 0;
        if (s_audio_to_pc && s_call && s_audio == ESP_HF_CLIENT_AUDIO_STATE_DISCONNECTED) esp_hf_client_connect_audio(s_peer);
        if (!s_audio_to_pc && s_audio != ESP_HF_CLIENT_AUDIO_STATE_DISCONNECTED) esp_hf_client_disconnect_audio(s_peer);
        emit_hfp();
    } else if (strncmp(line, "VOL ", 4) == 0) {
        int v = atoi(line + 8);
        if (strncmp(line + 4, "SPK ", 4) == 0) esp_hf_client_volume_update(ESP_HF_VOLUME_CONTROL_TARGET_SPK, v);
        else if (strncmp(line + 4, "MIC ", 4) == 0) esp_hf_client_volume_update(ESP_HF_VOLUME_CONTROL_TARGET_MIC, v);
    } else if (strcmp(line, "HFP CONNECT") == 0 || strncmp(line, "HFP CONNECT ", 12) == 0) {
        esp_bd_addr_t a;
        if ((line[11] == ' ' && parse(line + 12, a)) || (line[11] == 0 && last_peer(a))) {
            s_user_disconnected = false;
            esp_hf_client_connect(a);
        } else {
            serial_eventf("{\"t\":\"err\",\"code\":\"no_phone\",\"msg\":\"还没有配对过手机\"}");
        }
    } else if (strncmp(line, "PREFER ", 7) == 0) {
        esp_bd_addr_t a;
        if (strcmp(line + 7, "NONE") == 0) nv_set_str("pref", NULL);
        else if (parse(line + 7, a)) nv_set_str("pref", line + 7);
        emit_phones();
    } else if (strncmp(line, "SWITCH ", 7) == 0) {
        esp_bd_addr_t a;
        if (parse(line + 7, a) && is_bonded(a)) {
            s_user_disconnected = false;
            if (s_conn != ESP_HF_CLIENT_CONNECTION_STATE_DISCONNECTED && s_has_peer && memcmp(a, s_peer, 6) != 0) {
                memcpy(s_switch_to, a, 6);
                s_switch_pending = true;
                s_next_reconnect = esp_timer_get_time() + 1500000;
                esp_hf_client_disconnect(s_peer);
            } else if (s_conn == ESP_HF_CLIENT_CONNECTION_STATE_DISCONNECTED) {
                esp_hf_client_connect(a);
            }
        } else {
            serial_eventf("{\"t\":\"err\",\"code\":\"no_phone\",\"msg\":\"这台手机还没有配对\"}");
        }
    } else if (strcmp(line, "HFP DISCONNECT") == 0) {
        s_user_disconnected = true;
        if (s_has_peer) esp_hf_client_disconnect(s_peer);
    } else if (strcmp(line, "PHONES?") == 0 || strcmp(line, "HFP?") == 0) {
        emit_hfp();
        emit_call();
        emit_phones();
    } else if (strncmp(line, "UNPAIR_BT ", 10) == 0) {
        esp_bd_addr_t a;
        if (parse(line + 10, a)) {
            if (s_has_peer && memcmp(a, s_peer, 6) == 0) {
                s_user_disconnected = true;
                esp_hf_client_disconnect(a);
            }
            char key[13];
            key_of(a, key);
            nv_set_str(key, NULL);
            esp_bt_gap_remove_bond_device(a);
        }
    } else if (strcmp(line, "UNPAIR_BT") == 0) {
        int n = esp_bt_gap_get_bond_device_num();
        esp_bd_addr_t *list = n > 0 ? calloc(n, sizeof(esp_bd_addr_t)) : NULL;
        if (list) {
            esp_bt_gap_get_bond_device_list(&n, list);
            if (s_has_peer) esp_hf_client_disconnect(s_peer);
            s_user_disconnected = true;
            for (int i = 0; i < n; i++) esp_bt_gap_remove_bond_device(list[i]);
            free(list);
        }
        nv_set_str("last", NULL);
    } else {
        handled = false;
    }
    UNLOCK();
    return handled;
}

void hfp_init(hfp_pairing_open_fn pairing_open) {
    s_lock = xSemaphoreCreateRecursiveMutex();
    s_pairing_open = pairing_open;
    esp_bt_gap_register_callback(gap_cb);
    // 设备类别：音频 / 免提（手机据此显示为耳机/车载类设备）
    esp_bt_cod_t cod = {.major = ESP_BT_COD_MAJOR_DEV_AV, .minor = 0x02, .service = ESP_BT_COD_SRVC_AUDIO | ESP_BT_COD_SRVC_TELEPHONY};
    esp_bt_gap_set_cod(cod, ESP_BT_SET_COD_ALL);
    // SSP：无输入输出（Just Works），手机上只弹一次“配对”确认，和普通蓝牙耳机一样
    esp_bt_io_cap_t iocap = ESP_BT_IO_CAP_NONE;
    esp_bt_gap_set_security_param(ESP_BT_SP_IOCAP_MODE, &iocap, sizeof iocap);
    serial_set_frame_handler(on_frame);
    esp_hf_client_register_callback(hf_cb);
    esp_hf_client_init();
    s_discoverable = true; // 强制第一次设置
    s_discoverable = !(s_pairing_open() || esp_bt_gap_get_bond_device_num() <= 0);
    update_scan_mode();
    // 开机后 1 秒回连上次的手机
    s_next_reconnect = esp_timer_get_time() + 1000000;
}
