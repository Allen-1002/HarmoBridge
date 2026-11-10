// 与电脑之间的 USB 串口文本协议（见 docs/esp32-serial.md）。
#pragma once

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*serial_cmd_handler_t)(char *line);

void serial_link_start(serial_cmd_handler_t handler);
// 输出一整行（自动加换行），线程安全。
void serial_send_line(const char *line);
// printf 风格，输出 @{...} 事件行。
void serial_eventf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#ifdef __cplusplus
}
#endif
