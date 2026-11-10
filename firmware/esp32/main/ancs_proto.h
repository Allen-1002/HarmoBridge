// ANCS（Apple Notification Center Service）协议的纯逻辑部分：
// 解析 Notification Source、拼 Control Point 命令、重组 Data Source 分片、输出 JSON。
// 不依赖 ESP-IDF，可以在电脑上用 test/ancs_proto_test.c 单元测试。
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Notification Source 事件
enum { ANCS_EVT_ADDED = 0, ANCS_EVT_MODIFIED = 1, ANCS_EVT_REMOVED = 2 };

// EventFlags
enum {
    ANCS_FLAG_SILENT = 1 << 0,
    ANCS_FLAG_IMPORTANT = 1 << 1,
    ANCS_FLAG_PRE_EXISTING = 1 << 2,
    ANCS_FLAG_POSITIVE_ACTION = 1 << 3,
    ANCS_FLAG_NEGATIVE_ACTION = 1 << 4,
};

// Control Point 命令
enum { ANCS_CMD_GET_NOTIF_ATTR = 0, ANCS_CMD_GET_APP_ATTR = 1, ANCS_CMD_PERFORM_ACTION = 2 };

// 通知属性
enum {
    ANCS_ATTR_APP_ID = 0,
    ANCS_ATTR_TITLE = 1,
    ANCS_ATTR_SUBTITLE = 2,
    ANCS_ATTR_MESSAGE = 3,
    ANCS_ATTR_MESSAGE_SIZE = 4,
    ANCS_ATTR_DATE = 5,
    ANCS_ATTR_POS_LABEL = 6,
    ANCS_ATTR_NEG_LABEL = 7,
    ANCS_ATTR_COUNT = 8,
};

// 请求的最大长度（字节，UTF-8）
#define ANCS_TITLE_MAX 128
#define ANCS_SUBTITLE_MAX 128
#define ANCS_MESSAGE_MAX 512

typedef struct {
    uint8_t event_id;
    uint8_t flags;
    uint8_t category;
    uint8_t category_count;
    uint32_t uid;
} ancs_ns_event_t;

// 解析 8 字节的 Notification Source 通知。长度不对返回 false。
bool ancs_parse_ns(const uint8_t *data, size_t len, ancs_ns_event_t *out);

// 拼命令，返回写入的字节数（buf 不够返回 0）。
size_t ancs_build_get_notif_attrs(uint32_t uid, uint8_t *buf, size_t cap);
size_t ancs_build_get_app_attrs(const char *app_id, uint8_t *buf, size_t cap);
size_t ancs_build_perform_action(uint32_t uid, uint8_t action, uint8_t *buf, size_t cap);

// 一条通知的属性（字符串都以 NUL 结尾）
typedef struct {
    uint32_t uid;
    char app_id[96];
    char title[ANCS_TITLE_MAX + 1];
    char subtitle[ANCS_SUBTITLE_MAX + 1];
    char message[ANCS_MESSAGE_MAX + 1];
    char date[20];
    char pos_label[32];
    char neg_label[32];
} ancs_notif_attrs_t;

// Data Source 的重组器：一次只等一个响应。
#define ANCS_DS_BUF 1600

typedef enum { ANCS_DS_INCOMPLETE = 0, ANCS_DS_NOTIF_DONE, ANCS_DS_APP_DONE, ANCS_DS_ERROR } ancs_ds_result_t;

typedef struct {
    uint8_t expect;       // 期待的命令（ANCS_CMD_GET_NOTIF_ATTR / ANCS_CMD_GET_APP_ATTR），0xFF 表示空闲
    uint8_t buf[ANCS_DS_BUF];
    size_t len;
} ancs_ds_t;

void ancs_ds_reset(ancs_ds_t *ds, uint8_t expect);
// 追加一个分片。完成时把结果写到 notif 或 app_id/app_name。
ancs_ds_result_t ancs_ds_feed(ancs_ds_t *ds, const uint8_t *data, size_t len, ancs_notif_attrs_t *notif,
                              char *app_id, size_t app_id_cap, char *app_name, size_t app_name_cap);

// 把 UTF-8 字符串转成 JSON 字符串内容（不含两边引号）。非法 UTF-8 替换为 U+FFFD。
// 返回写入长度（不含 NUL），输出总是以 NUL 结尾。
size_t json_escape(const char *in, char *out, size_t cap);

#ifdef __cplusplus
}
#endif
