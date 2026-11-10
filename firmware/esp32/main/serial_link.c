#include "serial_link.h"

#include <stdio.h>
#include <string.h>

#include "driver/uart.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_timer.h"

#define LINK_UART UART_NUM_0
#define LINK_BAUD 115200
#define CMD_LINE_MAX 256

static SemaphoreHandle_t tx_lock;
static SemaphoreHandle_t fmt_lock;
static serial_cmd_handler_t cmd_handler;
static serial_frame_handler_t frame_handler;
static volatile int cur_baud = LINK_BAUD;
static volatile int64_t last_rx_us;

void serial_set_frame_handler(serial_frame_handler_t h) { frame_handler = h; }
int serial_get_baud(void) { return cur_baud; }
uint32_t serial_ms_since_rx(void) { return (uint32_t)((esp_timer_get_time() - last_rx_us) / 1000); }

void serial_send_frame(uint8_t type, uint16_t seq, const uint8_t *data, uint16_t len) {
    if (!tx_lock) return;
    uint8_t hdr[7] = {0xFE, 0xA5, type, (uint8_t)len, (uint8_t)(len >> 8), (uint8_t)seq, (uint8_t)(seq >> 8)};
    xSemaphoreTake(tx_lock, portMAX_DELAY);
    uart_write_bytes(LINK_UART, hdr, sizeof hdr);
    uart_write_bytes(LINK_UART, data, len);
    xSemaphoreGive(tx_lock);
}

void serial_set_baud(int baud) {
    xSemaphoreTake(tx_lock, portMAX_DELAY);
    uart_wait_tx_done(LINK_UART, pdMS_TO_TICKS(200));
    uart_set_baudrate(LINK_UART, baud);
    cur_baud = baud;
    xSemaphoreGive(tx_lock);
}

// ESP-IDF 日志也走这里，整行加锁输出，避免插进二进制帧中间
static int log_vprintf(const char *fmt, va_list ap) {
    char buf[256];
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    if (n <= 0 || !tx_lock) return n;
    if (n > (int)sizeof buf - 1) n = sizeof buf - 1;
    xSemaphoreTake(tx_lock, portMAX_DELAY);
    uart_write_bytes(LINK_UART, buf, n);
    xSemaphoreGive(tx_lock);
    return n;
}

void serial_send_line(const char *line) {
    if (!tx_lock) return;
    xSemaphoreTake(tx_lock, portMAX_DELAY);
    uart_write_bytes(LINK_UART, line, strlen(line));
    uart_write_bytes(LINK_UART, "\n", 1);
    xSemaphoreGive(tx_lock);
}

void serial_eventf(const char *fmt, ...) {
    static char buf[4096];
    if (!fmt_lock) return;
    xSemaphoreTake(fmt_lock, portMAX_DELAY);
    buf[0] = '@';
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf + 1, sizeof(buf) - 1, fmt, ap);
    va_end(ap);
    serial_send_line(buf);
    xSemaphoreGive(fmt_lock);
}

#define FRAME_MAX 1024
static void rx_task(void *arg) {
    char line[CMD_LINE_MAX];
    size_t len = 0;
    uint8_t ch[256];
    // 二进制帧解析状态：0 = 文本，1 = 收到 0xFE，2 = 读帧头，3 = 读数据
    static uint8_t frame[FRAME_MAX];
    int fstate = 0;
    uint8_t fhdr[5];
    int fhdr_n = 0;
    uint16_t flen = 0, fgot = 0;
    for (;;) {
        int n = uart_read_bytes(LINK_UART, ch, sizeof ch, pdMS_TO_TICKS(100));
        if (n > 0) last_rx_us = esp_timer_get_time();
        // 100 ms 没有数据：丢掉没收完的半个帧（电脑端中途断开时不会把后面的命令吃掉）
        if (n <= 0 && fstate != 0) fstate = 0;
        for (int i = 0; i < n; i++) {
            uint8_t b = ch[i];
            if (fstate == 1) {
                fstate = b == 0xA5 ? 2 : 0;
                fhdr_n = 0;
                continue;
            }
            if (fstate == 2) {
                fhdr[fhdr_n++] = b;
                if (fhdr_n == 5) {
                    flen = fhdr[1] | (fhdr[2] << 8);
                    fgot = 0;
                    fstate = flen > FRAME_MAX ? 0 : flen == 0 ? 0 : 3;
                }
                continue;
            }
            if (fstate == 3) {
                frame[fgot++] = b;
                if (fgot == flen) {
                    if (frame_handler) frame_handler(fhdr[0], fhdr[3] | (fhdr[4] << 8), frame, flen);
                    fstate = 0;
                }
                continue;
            }
            if (b == 0xFE) {
                fstate = 1;
                continue;
            }
            char c = (char)b;
            if (c == '\r') continue;
            if (c == '\n') {
                line[len] = 0;
                if (len > 0 && cmd_handler) cmd_handler(line);
                len = 0;
            } else if (len < CMD_LINE_MAX - 1) {
                line[len++] = c;
            }
        }
    }
}

void serial_link_start(serial_cmd_handler_t handler) {
    cmd_handler = handler;
    tx_lock = xSemaphoreCreateMutex();
    fmt_lock = xSemaphoreCreateMutex();
    uart_config_t cfg = {
        .baud_rate = LINK_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    // 控制台日志也在 UART0；电脑只解析以 HB- 或 @ 开头的行
    ESP_ERROR_CHECK(uart_driver_install(LINK_UART, 8192, 8192, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(LINK_UART, &cfg));
    esp_log_set_vprintf(log_vprintf);
    last_rx_us = esp_timer_get_time();
    xTaskCreate(rx_task, "serial_rx", 4096, NULL, 5, NULL);
}
