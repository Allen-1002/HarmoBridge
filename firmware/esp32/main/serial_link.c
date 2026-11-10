#include "serial_link.h"

#include <stdio.h>
#include <string.h>

#include "driver/uart.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"

#define LINK_UART UART_NUM_0
#define LINK_BAUD 115200
#define LINE_MAX 256

static SemaphoreHandle_t tx_lock;
static SemaphoreHandle_t fmt_lock;
static serial_cmd_handler_t cmd_handler;

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

static void rx_task(void *arg) {
    char line[LINE_MAX];
    size_t len = 0;
    uint8_t ch[64];
    for (;;) {
        int n = uart_read_bytes(LINK_UART, ch, sizeof ch, pdMS_TO_TICKS(100));
        for (int i = 0; i < n; i++) {
            char c = (char)ch[i];
            if (c == '\r') continue;
            if (c == '\n') {
                line[len] = 0;
                if (len > 0 && cmd_handler) cmd_handler(line);
                len = 0;
            } else if (len < LINE_MAX - 1) {
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
    ESP_ERROR_CHECK(uart_driver_install(LINK_UART, 2048, 8192, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(LINK_UART, &cfg));
    xTaskCreate(rx_task, "serial_rx", 4096, NULL, 5, NULL);
}
