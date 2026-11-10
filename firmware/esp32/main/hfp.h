// 经典蓝牙免提（HFP Hands-Free）：ESP32 作为手机的蓝牙免提设备，接打电话。
// 配对保存在 ESP32 的 NVS 里（跟着板子走），换电脑也能继续用。
#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef bool (*hfp_pairing_open_fn)(void);

// 在 bluedroid 启用后调用
void hfp_init(hfp_pairing_open_fn pairing_open);
// 处理电脑发来的命令；不是 HFP 命令返回 false
bool hfp_handle_command(const char *line);
// 配对窗口打开/关闭时调用（更新可被发现状态）
void hfp_pairing_changed(void);
// 每秒调用：自动回连
void hfp_tick(void);
// 输出状态（电脑连上时）
void hfp_emit_all(void);

#ifdef __cplusplus
}
#endif
