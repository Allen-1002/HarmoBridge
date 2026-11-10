// NotiBridge ESP32 固件
// 第一阶段：iPhone 通知（BLE ANCS）。ESP32 作为 BLE 外设广播，iPhone 连接并绑定后，
// ESP32 作为 GATT 客户端订阅 ANCS，把通知通过 USB 串口发给电脑。
// 断开后持续广播，iPhone 会自动重新连接（系统为 ANCS 维护连接）。

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ancs_proto.h"
#include "esp_app_desc.h"
#include "esp_bt.h"
#include "esp_bt_device.h"
#include "esp_bt_main.h"
#include "esp_gap_ble_api.h"
#include "esp_gattc_api.h"
#include "esp_gatt_common_api.h"
#include "esp_log.h"
#include "esp_gap_bt_api.h"
#include "esp_mac.h"
#include "hfp.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "serial_link.h"

static const char *TAG = "nb";

#define PROTO_VERSION 1
#define DEVICE_NAME "NotiBridge"
#define PAIRING_WINDOW_US (180LL * 1000 * 1000)
#define REQUEST_TIMEOUT_US (5LL * 1000 * 1000)
#define ENCRYPT_TIMEOUT_US (30LL * 1000 * 1000)

// ---- UUID（字符串形式，启动时转成小端字节）----
static esp_bt_uuid_t uuid_ancs, uuid_ns, uuid_cp, uuid_ds;

static void parse_uuid128(const char *s, esp_bt_uuid_t *out) {
    uint8_t be[16];
    int n = 0;
    for (const char *p = s; *p && n < 16; p++) {
        if (*p == '-') continue;
        unsigned v;
        sscanf(p, "%2x", &v);
        be[n++] = (uint8_t)v;
        p++;
    }
    out->len = ESP_UUID_LEN_128;
    for (int i = 0; i < 16; i++) out->uuid.uuid128[i] = be[15 - i];
}

static bool uuid_eq(const esp_bt_uuid_t *a, const esp_bt_uuid_t *b) {
    return a->len == ESP_UUID_LEN_128 && b->len == ESP_UUID_LEN_128 && memcmp(a->uuid.uuid128, b->uuid.uuid128, 16) == 0;
}

// ---- 状态（g_lock 保护）----
static SemaphoreHandle_t g_lock;
#define LOCK() xSemaphoreTakeRecursive(g_lock, portMAX_DELAY)
#define UNLOCK() xSemaphoreGiveRecursive(g_lock)

static esp_gatt_if_t g_gattc_if = ESP_GATT_IF_NONE;
static bool g_connected, g_encrypted, g_ancs_ready, g_advertising;
static bool g_gattc_open; // GATT 客户端虚拟连接已建立（外设角色也要 open 才能当客户端用）
static esp_ble_addr_type_t g_peer_addr_type;
static uint16_t g_conn_id;
static esp_bd_addr_t g_peer;
static int64_t g_connected_at;
static int64_t g_auth_early_at; // 连接事件之前就收到的加密完成
static uint16_t g_svc_start, g_svc_end;
static uint16_t h_ns, h_cp, h_ds;
static int g_search_retries;
static int64_t g_search_retry_at;
static int64_t g_pairing_until; // >0 表示配对窗口打开到此时刻
static uint8_t g_adv_cfg_pending;

// 请求队列：一次只发一条 Control Point 命令
typedef enum { REQ_GET = 0, REQ_ACTION = 1 } req_type_t;
typedef struct {
    req_type_t type;
    uint32_t uid;
    uint8_t ev, flags, cat, action;
} req_t;
#define QUEUE_CAP 64
static req_t g_queue[QUEUE_CAP];
static int g_q_head, g_q_len;
static bool g_in_flight;
static req_t g_cur_req;
static int64_t g_req_started;
static ancs_ds_t g_ds;
static ancs_notif_attrs_t g_cur_attrs;
static bool g_waiting_app_name;

// App 显示名缓存
#define APP_CACHE 32
static struct {
    char id[96];
    char name[64];
} g_apps[APP_CACHE];
static int g_apps_next;

static const char *app_name_lookup(const char *id) {
    for (int i = 0; i < APP_CACHE; i++)
        if (g_apps[i].id[0] && strcmp(g_apps[i].id, id) == 0) return g_apps[i].name;
    return NULL;
}

static void app_name_store(const char *id, const char *name) {
    if (app_name_lookup(id)) return;
    strlcpy(g_apps[g_apps_next].id, id, sizeof g_apps[0].id);
    strlcpy(g_apps[g_apps_next].name, name, sizeof g_apps[0].name);
    g_apps_next = (g_apps_next + 1) % APP_CACHE;
}

static void fmt_bda(const uint8_t *b, char *out) {
    sprintf(out, "%02x:%02x:%02x:%02x:%02x:%02x", b[0], b[1], b[2], b[3], b[4], b[5]);
}

static int bond_count(void) {
    int n = esp_ble_get_bond_device_num();
    return n < 0 ? 0 : n;
}

static bool pairing_window_open(void) { return g_pairing_until > 0 && esp_timer_get_time() < g_pairing_until; }

static bool pairing_allowed(void) { return bond_count() == 0 || pairing_window_open(); }

static void emit_state(void) {
    const char *ble = g_ancs_ready ? "ready" : g_encrypted ? "encrypted" : g_connected ? "connected"
                                             : g_advertising ? "advertising" : "idle";
    char peer[18] = "";
    if (g_connected) fmt_bda(g_peer, peer);
    serial_eventf("{\"t\":\"state\",\"ble\":\"%s\",\"peer\":\"%s\",\"bonds\":%d,\"pairing\":%s}", ble, peer,
                  bond_count(), pairing_allowed() ? "true" : "false");
}

static void emit_error(const char *code, const char *msg) {
    serial_eventf("{\"t\":\"err\",\"code\":\"%s\",\"msg\":\"%s\"}", code, msg);
}

static void emit_step(const char *msg) { serial_eventf("{\"t\":\"step\",\"msg\":\"%s\"}", msg); }

// ANCS 设置失败（iPhone 还没允许共享通知、服务暂时没出现等）时，每 4 秒从发现服务重新开始，最多 2 分钟
#define SETUP_RETRY_MAX 30
static void schedule_retry(const char *code, const char *msg) {
    if (g_search_retries < SETUP_RETRY_MAX) {
        g_search_retries++;
        g_search_retry_at = esp_timer_get_time() + 4000000;
        if (g_search_retries == 1 || g_search_retries % 5 == 0) emit_error(code, msg);
    } else {
        emit_error(code, "多次重试仍失败，请在 iPhone 上忽略此设备后重新配对");
    }
}

static void emit_bonds(void);
static void read_peer_name(void);
static void name_get(const uint8_t *bda, char *out, size_t cap);
static void name_set(const uint8_t *bda, const char *name);
static bool g_reading_name;

// ---- 广播 ----
static esp_ble_adv_params_t adv_params = {
    .adv_int_min = 0xA0, // 100 ms
    .adv_int_max = 0xF0, // 150 ms
    .adv_type = ADV_TYPE_IND,
    .own_addr_type = BLE_ADDR_TYPE_PUBLIC,
    .channel_map = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

static void start_advertising(void) {
    if (!g_connected) esp_ble_gap_start_advertising(&adv_params);
}

static void configure_advertising(void) {
    // 广播：Flags + 128 位服务请求（ANCS），iOS 据此识别通知设备；名字放在扫描响应
    uint8_t adv[3 + 18];
    adv[0] = 2; adv[1] = 0x01; adv[2] = 0x06;
    adv[3] = 17; adv[4] = 0x15;
    memcpy(adv + 5, uuid_ancs.uuid.uuid128, 16);
    uint8_t rsp[2 + sizeof(DEVICE_NAME) - 1];
    rsp[0] = sizeof(DEVICE_NAME);
    rsp[1] = 0x09;
    memcpy(rsp + 2, DEVICE_NAME, sizeof(DEVICE_NAME) - 1);
    g_adv_cfg_pending = 2;
    esp_ble_gap_config_adv_data_raw(adv, sizeof adv);
    esp_ble_gap_config_scan_rsp_data_raw(rsp, sizeof rsp);
}

// ---- 断开后的清理 ----
static void reset_link(void) {
    g_connected = g_encrypted = g_ancs_ready = g_gattc_open = false;
    g_svc_start = g_svc_end = 0;
    h_ns = h_cp = h_ds = 0;
    g_q_len = g_q_head = 0;
    g_in_flight = false;
    g_waiting_app_name = false;
    g_reading_name = false;
    g_search_retries = 0;
    g_search_retry_at = 0;
    ancs_ds_reset(&g_ds, 0xFF);
}

// ---- 请求队列 ----
static void pump(void);

static void finish_request(void) {
    g_in_flight = false;
    g_waiting_app_name = false;
    ancs_ds_reset(&g_ds, 0xFF);
    pump();
}

static void enqueue(req_t r) {
    if (r.type == REQ_GET) {
        // 同一条通知已经在排队：更新事件信息即可
        for (int i = 0; i < g_q_len; i++) {
            req_t *q = &g_queue[(g_q_head + i) % QUEUE_CAP];
            if (q->type == REQ_GET && q->uid == r.uid) {
                q->ev = r.ev;
                q->flags = r.flags;
                q->cat = r.cat;
                return;
            }
        }
    }
    if (g_q_len == QUEUE_CAP) {
        // 满了丢掉最旧的（通常是连接时补发的旧通知）
        g_q_head = (g_q_head + 1) % QUEUE_CAP;
        g_q_len--;
    }
    g_queue[(g_q_head + g_q_len) % QUEUE_CAP] = r;
    g_q_len++;
    pump();
}

static void dequeue_uid(uint32_t uid) {
    int w = 0;
    for (int i = 0; i < g_q_len; i++) {
        req_t q = g_queue[(g_q_head + i) % QUEUE_CAP];
        if (q.type == REQ_GET && q.uid == uid) continue;
        g_queue[(g_q_head + w) % QUEUE_CAP] = q;
        w++;
    }
    g_q_len = w;
}

static void write_cp(const uint8_t *buf, size_t len) {
    esp_ble_gattc_write_char(g_gattc_if, g_conn_id, h_cp, len, (uint8_t *)buf, ESP_GATT_WRITE_TYPE_RSP,
                             ESP_GATT_AUTH_REQ_NONE);
}

static void pump(void) {
    if (g_in_flight || !g_ancs_ready || g_q_len == 0) return;
    g_cur_req = g_queue[g_q_head];
    g_q_head = (g_q_head + 1) % QUEUE_CAP;
    g_q_len--;
    uint8_t buf[64];
    size_t n;
    if (g_cur_req.type == REQ_GET) {
        n = ancs_build_get_notif_attrs(g_cur_req.uid, buf, sizeof buf);
        ancs_ds_reset(&g_ds, ANCS_CMD_GET_NOTIF_ATTR);
    } else {
        n = ancs_build_perform_action(g_cur_req.uid, g_cur_req.action, buf, sizeof buf);
    }
    g_in_flight = true;
    g_req_started = esp_timer_get_time();
    write_cp(buf, n);
}

static void emit_notification(const ancs_notif_attrs_t *a, const char *app_name) {
    static char e_app[200], e_name[140], e_title[ANCS_TITLE_MAX * 2 + 8], e_sub[ANCS_SUBTITLE_MAX * 2 + 8],
        e_msg[ANCS_MESSAGE_MAX * 2 + 8], e_pos[70], e_neg[70], e_date[24];
    json_escape(a->app_id, e_app, sizeof e_app);
    json_escape(app_name ? app_name : "", e_name, sizeof e_name);
    json_escape(a->title, e_title, sizeof e_title);
    json_escape(a->subtitle, e_sub, sizeof e_sub);
    json_escape(a->message, e_msg, sizeof e_msg);
    json_escape(a->pos_label, e_pos, sizeof e_pos);
    json_escape(a->neg_label, e_neg, sizeof e_neg);
    json_escape(a->date, e_date, sizeof e_date);
    char peer[18];
    fmt_bda(g_peer, peer);
    // peer：发来通知的 iPhone（与 bonds 事件里的 addr 相同）
    serial_eventf("{\"t\":\"notif\",\"ev\":\"%s\",\"uid\":%" PRIu32 ",\"flags\":%u,\"cat\":%u,\"app\":\"%s\","
                  "\"appName\":\"%s\",\"title\":\"%s\",\"sub\":\"%s\",\"msg\":\"%s\",\"date\":\"%s\","
                  "\"pos\":\"%s\",\"neg\":\"%s\",\"peer\":\"%s\"}",
                  g_cur_req.ev == ANCS_EVT_MODIFIED ? "mod" : "add", a->uid, g_cur_req.flags, g_cur_req.cat, e_app,
                  e_name, e_title, e_sub, e_msg, e_date, e_pos, e_neg, peer);
}

static void on_data_source(const uint8_t *data, size_t len) {
    if (!g_in_flight || g_cur_req.type != REQ_GET) return;
    char app_id[96], app_name[64];
    ancs_ds_result_t r = ancs_ds_feed(&g_ds, data, len, &g_cur_attrs, app_id, sizeof app_id, app_name,
                                      sizeof app_name);
    if (r == ANCS_DS_NOTIF_DONE) {
        const char *name = app_name_lookup(g_cur_attrs.app_id);
        if (name || g_cur_attrs.app_id[0] == 0) {
            emit_notification(&g_cur_attrs, name);
            finish_request();
        } else {
            // 先查 App 显示名再输出
            uint8_t buf[128];
            size_t n = ancs_build_get_app_attrs(g_cur_attrs.app_id, buf, sizeof buf);
            if (n == 0) {
                emit_notification(&g_cur_attrs, NULL);
                finish_request();
                return;
            }
            g_waiting_app_name = true;
            ancs_ds_reset(&g_ds, ANCS_CMD_GET_APP_ATTR);
            g_req_started = esp_timer_get_time();
            write_cp(buf, n);
        }
    } else if (r == ANCS_DS_APP_DONE) {
        app_name_store(app_id, app_name);
        emit_notification(&g_cur_attrs, app_name);
        finish_request();
    } else if (r == ANCS_DS_ERROR) {
        if (g_waiting_app_name) emit_notification(&g_cur_attrs, NULL);
        else emit_error("ds_parse", "通知数据格式不对，已跳过");
        finish_request();
    }
}

static void on_notification_source(const uint8_t *data, size_t len) {
    ancs_ns_event_t e;
    if (!ancs_parse_ns(data, len, &e)) return;
    if (e.event_id == ANCS_EVT_REMOVED) {
        dequeue_uid(e.uid);
        char peer[18];
        fmt_bda(g_peer, peer);
        serial_eventf("{\"t\":\"removed\",\"uid\":%" PRIu32 ",\"peer\":\"%s\"}", e.uid, peer);
        return;
    }
    req_t r = {.type = REQ_GET, .uid = e.uid, .ev = e.event_id, .flags = e.flags, .cat = e.category};
    enqueue(r);
}

// ---- ANCS 发现与订阅 ----
static void subscribe(uint16_t char_handle) {
    esp_ble_gattc_register_for_notify(g_gattc_if, g_peer, char_handle);
}

static void write_cccd(uint16_t char_handle) {
    esp_gattc_descr_elem_t d;
    uint16_t count = 1;
    esp_bt_uuid_t cccd = {.len = ESP_UUID_LEN_16, .uuid.uuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG};
    esp_gatt_status_t st =
        esp_ble_gattc_get_descr_by_char_handle(g_gattc_if, g_conn_id, char_handle, cccd, &d, &count);
    if (st != ESP_GATT_OK || count == 0) {
        schedule_retry("cccd", "找不到 ANCS 订阅描述符，稍后重试");
        return;
    }
    uint8_t on[2] = {0x01, 0x00};
    esp_ble_gattc_write_char_descr(g_gattc_if, g_conn_id, d.handle, sizeof on, on, ESP_GATT_WRITE_TYPE_RSP,
                                   ESP_GATT_AUTH_REQ_NONE);
}

static uint16_t g_cccd_target; // 正在写哪个特征的订阅

static void discover_chars(void) {
    uint16_t count = 0;
    esp_ble_gattc_get_attr_count(g_gattc_if, g_conn_id, ESP_GATT_DB_CHARACTERISTIC, g_svc_start, g_svc_end, 0,
                                 &count);
    if (count == 0) {
        schedule_retry("ancs_chars", "ANCS 服务里没有特征，稍后重试");
        return;
    }
    esp_gattc_char_elem_t *chars = calloc(count, sizeof(*chars));
    if (!chars) return;
    if (esp_ble_gattc_get_all_char(g_gattc_if, g_conn_id, g_svc_start, g_svc_end, chars, &count, 0) ==
        ESP_GATT_OK) {
        for (int i = 0; i < count; i++) {
            if (uuid_eq(&chars[i].uuid, &uuid_ns)) h_ns = chars[i].char_handle;
            else if (uuid_eq(&chars[i].uuid, &uuid_cp)) h_cp = chars[i].char_handle;
            else if (uuid_eq(&chars[i].uuid, &uuid_ds)) h_ds = chars[i].char_handle;
        }
    }
    free(chars);
    if (!h_ns || !h_cp || !h_ds) {
        schedule_retry("ancs_chars", "ANCS 特征不完整，稍后重试");
        return;
    }
    emit_step("已找到 ANCS，正在订阅");
    // 先订阅 Data Source，再订阅 Notification Source（订阅 NS 后 iPhone 立刻补发现有通知）
    subscribe(h_ds);
}

static void search_ancs(void);

// 加密完成且客户端连接已建立后开始发现 ANCS
static int64_t g_discovery_at;

static void start_discovery(void) {
    if (!g_encrypted || !g_gattc_open) return;
    g_discovery_at = esp_timer_get_time();
    emit_step("已加密，正在查找 iPhone 的通知服务");
    if (esp_ble_gattc_send_mtu_req(g_gattc_if, g_conn_id) != ESP_OK) search_ancs();
}

static void search_ancs(void) {
    g_svc_start = g_svc_end = 0;
    esp_ble_gattc_search_service(g_gattc_if, g_conn_id, &uuid_ancs);
}

// ---- GAP 回调 ----
static void gap_cb(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
    LOCK();
    switch (event) {
    case ESP_GAP_BLE_ADV_DATA_RAW_SET_COMPLETE_EVT:
    case ESP_GAP_BLE_SCAN_RSP_DATA_RAW_SET_COMPLETE_EVT:
        if (g_adv_cfg_pending > 0 && --g_adv_cfg_pending == 0) start_advertising();
        break;
    case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
        g_advertising = param->adv_start_cmpl.status == ESP_BT_STATUS_SUCCESS;
        if (!g_advertising) emit_error("adv", "无法开始广播");
        emit_state();
        break;
    case ESP_GAP_BLE_ADV_STOP_COMPLETE_EVT:
        g_advertising = false;
        break;
    case ESP_GAP_BLE_SEC_REQ_EVT: {
        bool ok = pairing_allowed();
        esp_ble_gap_security_rsp(param->ble_security.ble_req.bd_addr, ok);
        if (!ok) {
            emit_error("pairing_closed", "有新 iPhone 请求配对，但配对窗口未打开");
            esp_ble_gap_disconnect(param->ble_security.ble_req.bd_addr);
        }
        break;
    }
    case ESP_GAP_BLE_AUTH_CMPL_EVT:
        if (param->ble_security.auth_cmpl.success) {
            // 配对窗口不在这里关闭：同一台 iPhone 接着还要做经典蓝牙（通话）配对
            if (!g_connected) {
                // 加密完成事件有时比 GATT 的连接事件先到（iPhone 重连时自己发起加密）：记下来，连接事件里接上
                g_auth_early_at = esp_timer_get_time();
                break;
            }
            g_encrypted = true;
            emit_state();
            start_discovery();
        } else {
            char msg[64];
            snprintf(msg, sizeof msg, "加密失败（原因 0x%02x）", param->ble_security.auth_cmpl.fail_reason);
            emit_error("auth", msg);
            esp_ble_gap_disconnect(param->ble_security.auth_cmpl.bd_addr);
        }
        break;
    case ESP_GAP_BLE_REMOVE_BOND_DEV_COMPLETE_EVT:
        emit_state();
        emit_bonds();
        break;
    default:
        break;
    }
    UNLOCK();
}

// ---- GATT 客户端回调 ----
static void gattc_cb(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t *param) {
    LOCK();
    switch (event) {
    case ESP_GATTC_REG_EVT:
        g_gattc_if = gattc_if;
        esp_ble_gap_set_device_name(DEVICE_NAME);
        configure_advertising();
        break;
    case ESP_GATTC_CONNECT_EVT:
        reset_link();
        g_connected = true;
        g_advertising = false;
        g_conn_id = param->connect.conn_id;
        memcpy(g_peer, param->connect.remote_bda, sizeof(esp_bd_addr_t));
        g_peer_addr_type = param->connect.ble_addr_type;
        g_connected_at = esp_timer_get_time();
        emit_state();
        {
            // iPhone 连进来后，在同一条链路上建立 GATT 客户端连接（OPEN_EVT 里拿到可用的 conn_id）
            esp_ble_gatt_creat_conn_params_t cp = {0};
            memcpy(cp.remote_bda, g_peer, ESP_BD_ADDR_LEN);
            cp.remote_addr_type = g_peer_addr_type;
            cp.own_addr_type = BLE_ADDR_TYPE_PUBLIC;
            cp.is_direct = true;
            cp.is_aux = false;
            cp.phy_mask = 0;
            esp_ble_gattc_enh_open(g_gattc_if, &cp);
        }
        // 已绑定的 iPhone 用保存的密钥直接加密；新 iPhone 会进入配对（SEC_REQ_EVT 里决定是否接受）
        if (g_auth_early_at > 0 && esp_timer_get_time() - g_auth_early_at < 5000000) {
            g_auth_early_at = 0;
            g_encrypted = true;
            emit_state();
        } else {
            esp_ble_set_encryption(g_peer, ESP_BLE_SEC_ENCRYPT_NO_MITM);
        }
        break;
    case ESP_GATTC_OPEN_EVT:
        if (param->open.status == ESP_GATT_OK) {
            g_conn_id = param->open.conn_id;
            g_gattc_open = true;
            start_discovery();
        } else {
            char msg[64];
            snprintf(msg, sizeof msg, "建立 GATT 客户端连接失败（0x%02x）", param->open.status);
            emit_error("gattc_open", msg);
        }
        break;
    case ESP_GATTC_DISCONNECT_EVT:
        reset_link();
        emit_state();
        emit_bonds();
        start_advertising();
        break;
    case ESP_GATTC_CFG_MTU_EVT:
        search_ancs();
        break;
    case ESP_GATTC_SEARCH_RES_EVT:
        if (uuid_eq(&param->search_res.srvc_id.uuid, &uuid_ancs)) {
            g_svc_start = param->search_res.start_handle;
            g_svc_end = param->search_res.end_handle;
        }
        break;
    case ESP_GATTC_SEARCH_CMPL_EVT:
        if (g_svc_start) {
            discover_chars();
        } else {
            // iPhone 在加密后、或用户允许共享通知后才公开 ANCS
            schedule_retry("no_ancs", "还没有找到 iPhone 的通知服务：请在 iPhone 蓝牙设置里打开 NotiBridge 的“共享系统通知”");
        }
        break;
    case ESP_GATTC_SRVC_CHG_EVT:
        if (g_encrypted) {
            g_ancs_ready = false;
            h_ns = h_cp = h_ds = 0;
            search_ancs();
        }
        break;
    case ESP_GATTC_REG_FOR_NOTIFY_EVT:
        if (param->reg_for_notify.status == ESP_GATT_OK) {
            g_cccd_target = param->reg_for_notify.handle;
            write_cccd(param->reg_for_notify.handle);
        } else {
            schedule_retry("notify_reg", "订阅 ANCS 失败，稍后重试");
        }
        break;
    case ESP_GATTC_WRITE_DESCR_EVT:
        if (param->write.status != ESP_GATT_OK) {
            char msg[128];
            snprintf(msg, sizeof msg, "iPhone 拒绝订阅通知（0x%02x），请允许共享系统通知", param->write.status);
            schedule_retry("cccd_write", msg);
            break;
        }
        if (g_cccd_target == h_ds) {
            subscribe(h_ns);
        } else if (g_cccd_target == h_ns) {
            g_ancs_ready = true;
            g_search_retries = 0;
            emit_state();
            emit_bonds();
            read_peer_name();
            pump();
        }
        break;
    case ESP_GATTC_READ_CHAR_EVT:
        if (g_reading_name) {
            g_reading_name = false;
            if (param->read.status == ESP_GATT_OK && param->read.value_len > 0) {
                char name[64];
                size_t n = param->read.value_len < sizeof name - 1 ? param->read.value_len : sizeof name - 1;
                memcpy(name, param->read.value, n);
                name[n] = 0;
                char old[64];
                name_get(g_peer, old, sizeof old);
                if (strcmp(old, name) != 0) {
                    name_set(g_peer, name);
                    emit_bonds();
                }
            }
        }
        break;
    case ESP_GATTC_NOTIFY_EVT:
        if (param->notify.handle == h_ns) on_notification_source(param->notify.value, param->notify.value_len);
        else if (param->notify.handle == h_ds) on_data_source(param->notify.value, param->notify.value_len);
        break;
    case ESP_GATTC_WRITE_CHAR_EVT:
        if (param->write.handle == h_cp && g_in_flight) {
            if (param->write.status != ESP_GATT_OK) {
                // 0xA0 未知命令、0xA1 格式错误、0xA2 参数无效（通知已不存在）、0xA3 动作失败
                if (g_waiting_app_name) {
                    emit_notification(&g_cur_attrs, NULL);
                } else if (g_cur_req.type == REQ_ACTION) {
                    char msg[48];
                    snprintf(msg, sizeof msg, "iPhone 拒绝了操作（0x%02x）", param->write.status);
                    emit_error("action", msg);
                }
                finish_request();
            } else if (g_cur_req.type == REQ_ACTION) {
                serial_eventf("{\"t\":\"acted\",\"uid\":%" PRIu32 ",\"action\":%u}", g_cur_req.uid,
                              g_cur_req.action);
                finish_request();
            }
        }
        break;
    default:
        break;
    }
    UNLOCK();
}

// ---- 每秒检查超时 ----
static void tick(void *arg) {
    LOCK();
    int64_t now = esp_timer_get_time();
    if (g_in_flight && now - g_req_started > REQUEST_TIMEOUT_US) {
        if (g_waiting_app_name) emit_notification(&g_cur_attrs, NULL);
        finish_request();
    }
    if (g_pairing_until > 0 && now >= g_pairing_until) {
        g_pairing_until = 0;
        emit_state();
    }
    if (g_connected && !g_encrypted && now - g_connected_at > ENCRYPT_TIMEOUT_US) {
        emit_error("auth_timeout", "连接后 30 秒没有完成加密，已断开");
        esp_ble_gap_disconnect(g_peer);
        g_connected_at = now; // 避免重复断开
    }
    // 发现过程卡住（没有任何回调）时重来
    if (g_encrypted && g_gattc_open && !g_ancs_ready && g_search_retry_at == 0 && g_discovery_at > 0 &&
        now - g_discovery_at > 10000000) {
        g_discovery_at = now;
        schedule_retry("stuck", "查找通知服务没有响应，正在重试");
    }
    if (g_connected && g_encrypted && !g_gattc_open && now - g_connected_at > 15000000) {
        g_connected_at = now;
        emit_error("gattc_open", "GATT 客户端连接没有建立");
    }
    if (g_search_retry_at > 0 && now >= g_search_retry_at) {
        g_discovery_at = now;
        g_search_retry_at = 0;
        if (g_encrypted) search_ancs();
    }
    UNLOCK();
    if (serial_get_baud() != 115200 && serial_ms_since_rx() > 3000) serial_set_baud(115200);
    hfp_tick();
}

// ---- 已配对的 iPhone（名字存在 NVS 的 nb_names 里，键是去掉冒号的地址）----
static void name_key(const uint8_t *bda, char *key) {
    sprintf(key, "%02x%02x%02x%02x%02x%02x", bda[0], bda[1], bda[2], bda[3], bda[4], bda[5]);
}

static void name_get(const uint8_t *bda, char *out, size_t cap) {
    out[0] = 0;
    nvs_handle_t h;
    if (nvs_open("nb_names", NVS_READONLY, &h) != ESP_OK) return;
    char key[13];
    name_key(bda, key);
    size_t len = cap;
    if (nvs_get_str(h, key, out, &len) != ESP_OK) out[0] = 0;
    nvs_close(h);
}

static void name_set(const uint8_t *bda, const char *name) {
    nvs_handle_t h;
    if (nvs_open("nb_names", NVS_READWRITE, &h) != ESP_OK) return;
    char key[13];
    name_key(bda, key);
    if (name) nvs_set_str(h, key, name);
    else nvs_erase_key(h, key);
    nvs_commit(h);
    nvs_close(h);
}

static void emit_bonds(void) {
    int n = esp_ble_get_bond_device_num();
    if (n < 0) n = 0;
    esp_ble_bond_dev_t *list = n ? calloc(n, sizeof(*list)) : NULL;
    if (n && !list) return;
    if (n) esp_ble_get_bond_device_list(&n, list);
    static char buf[2048];
    size_t o = snprintf(buf, sizeof buf, "{\"t\":\"bonds\",\"list\":[");
    for (int i = 0; i < n && o < sizeof buf - 200; i++) {
        char addr[18], name[64], esc[140];
        fmt_bda(list[i].bd_addr, addr);
        name_get(list[i].bd_addr, name, sizeof name);
        json_escape(name, esc, sizeof esc);
        bool conn = g_connected && memcmp(list[i].bd_addr, g_peer, 6) == 0;
        o += snprintf(buf + o, sizeof buf - o,
                      "%s{\"addr\":\"%s\",\"name\":\"%s\",\"connected\":%s,\"ready\":%s}", i ? "," : "",
                      addr, esc, conn ? "true" : "false", conn && g_ancs_ready ? "true" : "false");
    }
    snprintf(buf + o, sizeof buf - o, "]}");
    free(list);
    serial_eventf("%s", buf);
}

static bool parse_bda(const char *s, esp_bd_addr_t out) {
    unsigned v[6];
    if (sscanf(s, "%2x:%2x:%2x:%2x:%2x:%2x", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) != 6) return false;
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)v[i];
    return true;
}

// 读 iPhone 的设备名（GAP Device Name 0x2A00），例如 “Allen 的 iPhone”
static void read_peer_name(void) {
    esp_bt_uuid_t u = {.len = ESP_UUID_LEN_16, .uuid.uuid16 = ESP_GATT_UUID_GAP_DEVICE_NAME};
    g_reading_name = esp_ble_gattc_read_by_type(g_gattc_if, g_conn_id, 1, 0xFFFF, &u, ESP_GATT_AUTH_REQ_NONE) == ESP_OK;
}

// ---- 电脑发来的命令 ----
static void remove_bond(const uint8_t *bda) {
    if (g_connected && memcmp(bda, g_peer, 6) == 0) esp_ble_gap_disconnect(g_peer);
    name_set(bda, NULL);
    esp_ble_remove_bond_device((uint8_t *)bda);
}

static void remove_all_bonds(void) {
    int n = esp_ble_get_bond_device_num();
    if (n <= 0) return;
    esp_ble_bond_dev_t *list = calloc(n, sizeof(*list));
    if (!list) return;
    esp_ble_get_bond_device_list(&n, list);
    for (int i = 0; i < n; i++) remove_bond(list[i].bd_addr);
    free(list);
}

static void handle_command(char *line) {
    if (strcmp(line, "HB?") == 0) {
        char buf[128], mac[18];
        fmt_bda(esp_bt_dev_get_address(), mac);
        snprintf(buf, sizeof buf, "HB-ESP32 %s chip=esp32 ble=%s proto=%d", esp_app_get_description()->version,
                 mac, PROTO_VERSION);
        serial_send_line(buf);
        return;
    }
    LOCK();
    if (strcmp(line, "STATE?") == 0) {
        emit_state();
        hfp_emit_all();
    } else if (strcmp(line, "PAIR") == 0) {
        g_pairing_until = esp_timer_get_time() + PAIRING_WINDOW_US;
        emit_state();
        hfp_pairing_changed();
    } else if (strcmp(line, "UNPAIR") == 0) {
        if (g_connected) esp_ble_gap_disconnect(g_peer);
        remove_all_bonds();
        emit_state();
    } else if (strncmp(line, "UNPAIR ", 7) == 0) {
        esp_bd_addr_t bda;
        if (parse_bda(line + 7, bda)) remove_bond(bda);
        else emit_error("bad_addr", "地址格式不对");
    } else if (strcmp(line, "BONDS?") == 0) {
        emit_bonds();
    } else if (strncmp(line, "ACT ", 4) == 0) {
        char *end;
        unsigned long uid = strtoul(line + 4, &end, 10);
        unsigned long action = strtoul(end, NULL, 10);
        if (!g_ancs_ready) emit_error("not_ready", "iPhone 未连接");
        else enqueue((req_t){.type = REQ_ACTION, .uid = (uint32_t)uid, .action = action ? 1 : 0});
    } else if (strncmp(line, "BAUD ", 5) == 0) {
        // 通话时电脑把串口提速（音频需要约 70 KB/s）；电脑 3 秒没有数据就自动回到 115200
        int b = atoi(line + 5);
        if (b == 115200 || b == 921600 || b == 1500000 || b == 2000000) {
            serial_eventf("{\"t\":\"baud\",\"value\":%d}", b);
            serial_set_baud(b);
        } else {
            emit_error("bad_baud", "不支持的波特率");
        }
    } else if (strcmp(line, "PING") == 0) {
        // 电脑在高波特率下的心跳
    } else if (strcmp(line, "REBOOT") == 0) {
        esp_restart();
    } else {
        if (!hfp_handle_command(line)) emit_error("unknown_cmd", "未知命令");
    }
    UNLOCK();
}

void app_main(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    g_lock = xSemaphoreCreateRecursiveMutex();
    ancs_ds_reset(&g_ds, 0xFF);
    parse_uuid128("7905F431-B5CE-4E99-A40F-4B1E122D00D0", &uuid_ancs);
    parse_uuid128("9FBF120D-6301-42D9-8C58-25E699A21DBD", &uuid_ns);
    parse_uuid128("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9", &uuid_cp);
    parse_uuid128("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB", &uuid_ds);

    serial_link_start(handle_command);

    // 第一阶段只用 BLE；经典蓝牙（HFP 通话）在第二阶段加入
    // 双模：BLE（iPhone 通知）+ 经典蓝牙（HFP 通话）
    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BTDM));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());

    // 安全参数：Just Works + 绑定 + LE 安全连接（ANCS 要求加密）
    esp_ble_auth_req_t auth = ESP_LE_AUTH_REQ_SC_BOND;
    esp_ble_io_cap_t iocap = ESP_IO_CAP_NONE;
    uint8_t key_size = 16;
    uint8_t init_key = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    uint8_t rsp_key = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    esp_ble_gap_set_security_param(ESP_BLE_SM_AUTHEN_REQ_MODE, &auth, 1);
    esp_ble_gap_set_security_param(ESP_BLE_SM_IOCAP_MODE, &iocap, 1);
    esp_ble_gap_set_security_param(ESP_BLE_SM_MAX_KEY_SIZE, &key_size, 1);
    esp_ble_gap_set_security_param(ESP_BLE_SM_SET_INIT_KEY, &init_key, 1);
    esp_ble_gap_set_security_param(ESP_BLE_SM_SET_RSP_KEY, &rsp_key, 1);

    esp_bt_gap_set_device_name(DEVICE_NAME);
    hfp_init(pairing_window_open);
    ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_cb));
    ESP_ERROR_CHECK(esp_ble_gattc_register_callback(gattc_cb));
    ESP_ERROR_CHECK(esp_ble_gattc_app_register(0));
    esp_ble_gatt_set_local_mtu(247);

    const esp_timer_create_args_t targs = {.callback = tick, .name = "nb_tick"};
    esp_timer_handle_t timer;
    ESP_ERROR_CHECK(esp_timer_create(&targs, &timer));
    ESP_ERROR_CHECK(esp_timer_start_periodic(timer, 1000000));

    ESP_LOGI(TAG, "NotiBridge %s started", esp_app_get_description()->version);
}
