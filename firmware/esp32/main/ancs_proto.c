#include "ancs_proto.h"

#include <string.h>

static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void wr32(uint8_t *p, uint32_t v) {
    p[0] = v & 0xFF;
    p[1] = (v >> 8) & 0xFF;
    p[2] = (v >> 16) & 0xFF;
    p[3] = (v >> 24) & 0xFF;
}

bool ancs_parse_ns(const uint8_t *data, size_t len, ancs_ns_event_t *out) {
    if (len != 8 || data[0] > ANCS_EVT_REMOVED) return false;
    out->event_id = data[0];
    out->flags = data[1];
    out->category = data[2];
    out->category_count = data[3];
    out->uid = rd32(data + 4);
    return true;
}

size_t ancs_build_get_notif_attrs(uint32_t uid, uint8_t *buf, size_t cap) {
    // 命令 0 + UID + 属性列表（标题/副标题/正文带最大长度）
    const size_t need = 1 + 4 + 1 + 3 + 3 + 3 + 1 + 1 + 1;
    if (cap < need) return 0;
    size_t n = 0;
    buf[n++] = ANCS_CMD_GET_NOTIF_ATTR;
    wr32(buf + n, uid);
    n += 4;
    buf[n++] = ANCS_ATTR_APP_ID;
    buf[n++] = ANCS_ATTR_TITLE;
    buf[n++] = ANCS_TITLE_MAX & 0xFF;
    buf[n++] = ANCS_TITLE_MAX >> 8;
    buf[n++] = ANCS_ATTR_SUBTITLE;
    buf[n++] = ANCS_SUBTITLE_MAX & 0xFF;
    buf[n++] = ANCS_SUBTITLE_MAX >> 8;
    buf[n++] = ANCS_ATTR_MESSAGE;
    buf[n++] = ANCS_MESSAGE_MAX & 0xFF;
    buf[n++] = ANCS_MESSAGE_MAX >> 8;
    buf[n++] = ANCS_ATTR_DATE;
    buf[n++] = ANCS_ATTR_POS_LABEL;
    buf[n++] = ANCS_ATTR_NEG_LABEL;
    return n;
}

size_t ancs_build_get_app_attrs(const char *app_id, uint8_t *buf, size_t cap) {
    size_t id_len = strlen(app_id);
    if (cap < 1 + id_len + 1 + 1) return 0;
    size_t n = 0;
    buf[n++] = ANCS_CMD_GET_APP_ATTR;
    memcpy(buf + n, app_id, id_len);
    n += id_len;
    buf[n++] = 0;
    buf[n++] = 0; // DisplayName
    return n;
}

size_t ancs_build_perform_action(uint32_t uid, uint8_t action, uint8_t *buf, size_t cap) {
    if (cap < 6) return 0;
    buf[0] = ANCS_CMD_PERFORM_ACTION;
    wr32(buf + 1, uid);
    buf[5] = action;
    return 6;
}

void ancs_ds_reset(ancs_ds_t *ds, uint8_t expect) {
    ds->expect = expect;
    ds->len = 0;
}

static void copy_attr(char *dst, size_t cap, const uint8_t *src, size_t len) {
    if (len >= cap) len = cap - 1;
    memcpy(dst, src, len);
    dst[len] = 0;
}

// 尝试解析完整的通知属性响应。属性数量固定为 ancs_build_get_notif_attrs 请求的 7 个。
static ancs_ds_result_t parse_notif(ancs_ds_t *ds, ancs_notif_attrs_t *out) {
    const uint8_t *b = ds->buf;
    size_t len = ds->len;
    if (len < 5) return ANCS_DS_INCOMPLETE;
    size_t p = 5;
    ancs_notif_attrs_t tmp;
    memset(&tmp, 0, sizeof(tmp));
    tmp.uid = rd32(b + 1);
    for (int i = 0; i < 7; i++) {
        if (p + 3 > len) return ANCS_DS_INCOMPLETE;
        uint8_t id = b[p];
        size_t alen = (size_t)b[p + 1] | ((size_t)b[p + 2] << 8);
        p += 3;
        if (p + alen > len) return ANCS_DS_INCOMPLETE;
        const uint8_t *v = b + p;
        switch (id) {
        case ANCS_ATTR_APP_ID: copy_attr(tmp.app_id, sizeof(tmp.app_id), v, alen); break;
        case ANCS_ATTR_TITLE: copy_attr(tmp.title, sizeof(tmp.title), v, alen); break;
        case ANCS_ATTR_SUBTITLE: copy_attr(tmp.subtitle, sizeof(tmp.subtitle), v, alen); break;
        case ANCS_ATTR_MESSAGE: copy_attr(tmp.message, sizeof(tmp.message), v, alen); break;
        case ANCS_ATTR_DATE: copy_attr(tmp.date, sizeof(tmp.date), v, alen); break;
        case ANCS_ATTR_POS_LABEL: copy_attr(tmp.pos_label, sizeof(tmp.pos_label), v, alen); break;
        case ANCS_ATTR_NEG_LABEL: copy_attr(tmp.neg_label, sizeof(tmp.neg_label), v, alen); break;
        default: return ANCS_DS_ERROR;
        }
        p += alen;
    }
    *out = tmp;
    return ANCS_DS_NOTIF_DONE;
}

static ancs_ds_result_t parse_app(ancs_ds_t *ds, char *app_id, size_t id_cap, char *name, size_t name_cap) {
    const uint8_t *b = ds->buf;
    size_t len = ds->len;
    size_t p = 1;
    while (p < len && b[p] != 0) p++;
    if (p >= len) return ANCS_DS_INCOMPLETE;
    size_t id_len = p - 1;
    p++; // NUL
    if (p + 3 > len) return ANCS_DS_INCOMPLETE;
    if (b[p] != 0) return ANCS_DS_ERROR;
    size_t alen = (size_t)b[p + 1] | ((size_t)b[p + 2] << 8);
    p += 3;
    if (p + alen > len) return ANCS_DS_INCOMPLETE;
    copy_attr(app_id, id_cap, b + 1, id_len);
    copy_attr(name, name_cap, b + p, alen);
    return ANCS_DS_APP_DONE;
}

ancs_ds_result_t ancs_ds_feed(ancs_ds_t *ds, const uint8_t *data, size_t len, ancs_notif_attrs_t *notif,
                              char *app_id, size_t app_id_cap, char *app_name, size_t app_name_cap) {
    if (ds->expect == 0xFF) return ANCS_DS_ERROR;
    if (ds->len + len > sizeof(ds->buf)) {
        ancs_ds_reset(ds, 0xFF);
        return ANCS_DS_ERROR;
    }
    memcpy(ds->buf + ds->len, data, len);
    ds->len += len;
    if (ds->buf[0] != ds->expect) {
        ancs_ds_reset(ds, 0xFF);
        return ANCS_DS_ERROR;
    }
    ancs_ds_result_t r = ds->expect == ANCS_CMD_GET_NOTIF_ATTR
                             ? parse_notif(ds, notif)
                             : parse_app(ds, app_id, app_id_cap, app_name, app_name_cap);
    if (r != ANCS_DS_INCOMPLETE) ancs_ds_reset(ds, 0xFF);
    return r;
}

// 返回一个合法 UTF-8 字符的长度，非法返回 0
static size_t utf8_len(const unsigned char *s) {
    unsigned char c = s[0];
    if (c < 0x80) return 1;
    size_t n;
    uint32_t cp;
    if ((c & 0xE0) == 0xC0) { n = 2; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { n = 3; cp = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { n = 4; cp = c & 0x07; }
    else return 0;
    for (size_t i = 1; i < n; i++) {
        if ((s[i] & 0xC0) != 0x80) return 0;
        cp = (cp << 6) | (s[i] & 0x3F);
    }
    if ((n == 2 && cp < 0x80) || (n == 3 && cp < 0x800) || (n == 4 && (cp < 0x10000 || cp > 0x10FFFF))) return 0;
    if (cp >= 0xD800 && cp <= 0xDFFF) return 0;
    return n;
}

size_t json_escape(const char *in, char *out, size_t cap) {
    size_t o = 0;
    const unsigned char *s = (const unsigned char *)in;
    if (cap == 0) return 0;
    while (*s) {
        char tmp[8];
        size_t tlen;
        const char *src = tmp;
        size_t adv = 1;
        unsigned char c = *s;
        if (c == '"' || c == '\\') { tmp[0] = '\\'; tmp[1] = (char)c; tlen = 2; }
        else if (c == '\n') { memcpy(tmp, "\\n", 2); tlen = 2; }
        else if (c == '\r') { memcpy(tmp, "\\r", 2); tlen = 2; }
        else if (c == '\t') { memcpy(tmp, "\\t", 2); tlen = 2; }
        else if (c < 0x20) {
            static const char hex[] = "0123456789abcdef";
            memcpy(tmp, "\\u00", 4);
            tmp[4] = hex[c >> 4];
            tmp[5] = hex[c & 15];
            tlen = 6;
        } else if (c < 0x80) { tmp[0] = (char)c; tlen = 1; }
        else {
            adv = utf8_len(s);
            if (adv == 0) { memcpy(tmp, "\xEF\xBF\xBD", 3); tlen = 3; adv = 1; }
            else { src = (const char *)s; tlen = adv; }
        }
        if (o + tlen + 1 > cap) break; // 放不下就截断，不切断字符
        memcpy(out + o, src, tlen);
        o += tlen;
        s += adv;
    }
    out[o] = 0;
    return o;
}
