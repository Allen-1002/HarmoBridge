// 与电脑之间的 USB 串口文本协议（见 docs/esp32-serial.md）。
#pragma once

#include <stdarg.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*serial_cmd_handler_t)(char *line);

void serial_link_start(serial_cmd_handler_t handler);
// 输出一整行（自动加换行），线程安全。
void serial_send_line(const char *line);
// printf 风格，输出 @{...} 事件行。
void serial_eventf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// 二进制帧（通话音频）：0xFE 0xA5 类型(1) 长度(2, 小端) 序号(2, 小端) 数据。
// 0xFE 在 UTF-8 里不会出现，所以和文本行混在一起也能分开。
enum { FRAME_AUDIO_DOWN = 0x01, FRAME_AUDIO_UP = 0x02 };
typedef void (*serial_frame_handler_t)(uint8_t type, uint16_t seq, const uint8_t *data, uint16_t len);
void serial_set_frame_handler(serial_frame_handler_t handler);
void serial_send_frame(uint8_t type, uint16_t seq, const uint8_t *data, uint16_t len);
// 切换波特率（先把已排队的数据发完）
void serial_set_baud(int baud);
int serial_get_baud(void);
// 距离上次收到电脑数据的毫秒数
uint32_t serial_ms_since_rx(void);

#ifdef __cplusplus
}
#endif
