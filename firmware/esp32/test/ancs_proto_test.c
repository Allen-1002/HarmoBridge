// 在电脑上运行：firmware/esp32/test/run_tests.sh
#include "../main/ancs_proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;
#define CHECK(c)                                                         \
    do {                                                                 \
        if (!(c)) {                                                      \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); \
            failures++;                                                  \
        }                                                                \
    } while (0)

static size_t put_attr(uint8_t *b, uint8_t id, const char *v) {
    size_t l = strlen(v);
    b[0] = id;
    b[1] = l & 0xFF;
    b[2] = l >> 8;
    memcpy(b + 3, v, l);
    return 3 + l;
}

static void test_ns(void) {
    const uint8_t pkt[8] = {0, ANCS_FLAG_PRE_EXISTING | ANCS_FLAG_POSITIVE_ACTION, 4, 2, 0x78, 0x56, 0x34, 0x12};
    ancs_ns_event_t e;
    CHECK(ancs_parse_ns(pkt, 8, &e));
    CHECK(e.event_id == ANCS_EVT_ADDED && e.category == 4 && e.category_count == 2);
    CHECK(e.uid == 0x12345678);
    CHECK(e.flags & ANCS_FLAG_PRE_EXISTING);
    CHECK(!ancs_parse_ns(pkt, 7, &e));
    const uint8_t bad[8] = {3};
    CHECK(!ancs_parse_ns(bad, 8, &e));
}

static void test_build(void) {
    uint8_t b[64];
    size_t n = ancs_build_get_notif_attrs(0x01020304, b, sizeof(b));
    const uint8_t want[] = {0, 4, 3, 2, 1, 0, 1, 128, 0, 2, 128, 0, 3, 0, 2, 5, 6, 7};
    CHECK(n == sizeof(want) && memcmp(b, want, n) == 0);
    CHECK(ancs_build_get_notif_attrs(1, b, 5) == 0);
    n = ancs_build_get_app_attrs("com.apple.MobileSMS", b, sizeof(b));
    CHECK(n == 1 + 19 + 1 + 1 && b[0] == 1 && b[20] == 0 && b[21] == 0);
    n = ancs_build_perform_action(7, 1, b, sizeof(b));
    const uint8_t act[] = {2, 7, 0, 0, 0, 1};
    CHECK(n == 6 && memcmp(b, act, 6) == 0);
}

static void test_ds_notif_fragmented(void) {
    uint8_t resp[512];
    size_t n = 0;
    resp[n++] = 0;
    resp[n++] = 9; resp[n++] = 0; resp[n++] = 0; resp[n++] = 0;
    n += put_attr(resp + n, ANCS_ATTR_APP_ID, "com.tencent.xin");
    n += put_attr(resp + n, ANCS_ATTR_TITLE, "张三");
    n += put_attr(resp + n, ANCS_ATTR_SUBTITLE, "");
    n += put_attr(resp + n, ANCS_ATTR_MESSAGE, "晚上一起吃饭？\n\"好\"");
    n += put_attr(resp + n, ANCS_ATTR_DATE, "20261110T094500");
    n += put_attr(resp + n, ANCS_ATTR_POS_LABEL, "");
    n += put_attr(resp + n, ANCS_ATTR_NEG_LABEL, "清除");

    // 每种分片大小都要能重组
    for (size_t frag = 1; frag <= n; frag++) {
        ancs_ds_t ds;
        ancs_notif_attrs_t a;
        char id[8], name[8];
        ancs_ds_reset(&ds, ANCS_CMD_GET_NOTIF_ATTR);
        ancs_ds_result_t r = ANCS_DS_INCOMPLETE;
        for (size_t off = 0; off < n; off += frag) {
            size_t l = n - off < frag ? n - off : frag;
            CHECK(r == ANCS_DS_INCOMPLETE);
            r = ancs_ds_feed(&ds, resp + off, l, &a, id, sizeof id, name, sizeof name);
        }
        CHECK(r == ANCS_DS_NOTIF_DONE);
        if (r == ANCS_DS_NOTIF_DONE) {
            CHECK(a.uid == 9);
            CHECK(strcmp(a.app_id, "com.tencent.xin") == 0);
            CHECK(strcmp(a.title, "张三") == 0);
            CHECK(strcmp(a.message, "晚上一起吃饭？\n\"好\"") == 0);
            CHECK(strcmp(a.date, "20261110T094500") == 0);
            CHECK(strcmp(a.neg_label, "清除") == 0);
        }
        CHECK(ds.expect == 0xFF);
    }
}

static void test_ds_app_and_errors(void) {
    uint8_t resp[64];
    size_t n = 0;
    resp[n++] = 1;
    memcpy(resp + n, "com.apple.MobileSMS", 19);
    n += 19;
    resp[n++] = 0;
    n += put_attr(resp + n, 0, "信息");
    ancs_ds_t ds;
    ancs_notif_attrs_t a;
    char id[96], name[64];
    ancs_ds_reset(&ds, ANCS_CMD_GET_APP_ATTR);
    CHECK(ancs_ds_feed(&ds, resp, 10, &a, id, sizeof id, name, sizeof name) == ANCS_DS_INCOMPLETE);
    CHECK(ancs_ds_feed(&ds, resp + 10, n - 10, &a, id, sizeof id, name, sizeof name) == ANCS_DS_APP_DONE);
    CHECK(strcmp(id, "com.apple.MobileSMS") == 0 && strcmp(name, "信息") == 0);

    // 命令不符
    ancs_ds_reset(&ds, ANCS_CMD_GET_NOTIF_ATTR);
    CHECK(ancs_ds_feed(&ds, resp, n, &a, id, sizeof id, name, sizeof name) == ANCS_DS_ERROR);
    // 空闲时收到数据
    CHECK(ancs_ds_feed(&ds, resp, n, &a, id, sizeof id, name, sizeof name) == ANCS_DS_ERROR);
    // 溢出
    static uint8_t big[ANCS_DS_BUF + 1];
    ancs_ds_reset(&ds, ANCS_CMD_GET_NOTIF_ATTR);
    CHECK(ancs_ds_feed(&ds, big, sizeof big, &a, id, sizeof id, name, sizeof name) == ANCS_DS_ERROR);
}

static void test_json(void) {
    char out[64];
    json_escape("a\"b\\c\n\x01", out, sizeof out);
    CHECK(strcmp(out, "a\\\"b\\\\c\\n\\u0001") == 0);
    json_escape("中文", out, sizeof out);
    CHECK(strcmp(out, "中文") == 0);
    // 截断的 UTF-8（ANCS 按字节截断）
    json_escape("中\xE6\x96", out, sizeof out);
    CHECK(strcmp(out, "中\xEF\xBF\xBD\xEF\xBF\xBD") == 0);
    // 空间不够时不切断字符
    char small[5];
    json_escape("中文", small, sizeof small);
    CHECK(strcmp(small, "中") == 0);
    // 过长编码、代理区
    json_escape("\xC0\xAF\xED\xA0\x80", out, sizeof out);
    CHECK(strstr(out, "\xC0") == NULL && strstr(out, "\xED") == NULL);
}

int main(void) {
    test_ns();
    test_build();
    test_ds_notif_fragmented();
    test_ds_app_and_errors();
    test_json();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("ancs_proto: all tests passed\n");
    return 0;
}
