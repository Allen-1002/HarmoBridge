#!/bin/sh
# 在电脑上编译并运行固件纯逻辑测试
set -e
cd "$(dirname "$0")"
out="${TMPDIR:-/tmp}/ancs_proto_test"
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -o "$out" ancs_proto_test.c ../main/ancs_proto.c
"$out"
