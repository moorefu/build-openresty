#!/bin/bash
set -e

# Usage: benchmark.sh <包根目录> [结果文件]
#
# 用 ab (Apache Bench) 对构建产物做基准测试, 结果写入 markdown 文件
# (供 CI 上传 artifact / 拼入 Release 说明)。
#   - ab 来自 httpd-tools (yum 安装, 容器内自动处理)
#   - 吞吐数字不作发布门槛, 仅设极宽的"残废检测"下限 (MIN_RPS),
#     防止构建配置错误产出性能崩坏的二进制还照常发布
# 结果为共享 runner 上的参考值, 波动大, 仅供版本间粗对比。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${1:?Usage: $0 <包根目录> [结果文件]}" && pwd)"
PLATFORM="$(uname -s | cut -d_ -f1 | tr 'A-Z' 'a-z')"
ARCH="$(uname -m)"
OUT="${2:-$SCRIPT_DIR/benchmark-$PLATFORM-$ARCH.txt}"

NGINX="$ROOT/bin/openresty"
[ -x "$NGINX" ] || { echo "错误: $NGINX 不存在或不可执行" >&2; exit 1; }

# 残废检测下限 (req/s): 仅用于拦截"构建配置错误导致性能崩坏"(那类产物
# 只有几十 req/s), 不作性能门槛。Lua 场景在共享 runner 上正常为数千 req/s,
# 下限取 500 留足余量
MIN_RPS=500
PORT=12421
DUR=10          # 每场景压测秒数
NPROC=$(nproc)

log() { echo "==> $*" >&2; }

command -v ab >/dev/null 2>&1 || {
  log "安装 httpd-tools (ab)"
  yum install -y httpd-tools
}
command -v ab >/dev/null 2>&1 || { echo "错误: 找不到 ab" >&2; exit 1; }

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  PY="$(ls /opt/python/cp3*/bin/python3 2>/dev/null | head -1 || true)"
fi
[ -n "$PY" ] || { echo "错误: 找不到 python, 无法探测端口" >&2; exit 1; }

WORK="$(mktemp -d /tmp/or-bench.XXXXXX)"
chmod 755 "$WORK"
NGX_PID=
cleanup() { [ -z "$NGX_PID" ] || kill "$NGX_PID" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

# ---------- 启动被测实例 ----------
# 静态 64B 页 + Lua hello 两个压测路径; daemon off 便于进程管理
mkdir -p "$WORK/conf" "$WORK/logs"
printf 'or-bench-static' > "$WORK/index64.txt"
cat > "$WORK/conf/nginx.conf" <<EOF
daemon off;
worker_processes 2;
error_log logs/error.log warn;
pid logs/nginx.pid;
events { worker_connections 1024; }
http {
  lua_package_path "$ROOT/lualib/?.lua;$ROOT/site/lualib/?.lua;;";
  lua_package_cpath "$ROOT/luajit/lib/?.so;;";
  access_log off;
  server {
    listen 127.0.0.1:$PORT;
    location = /s64 { default_type text/plain; alias "$WORK/index64.txt"; }
    location = /lua { default_type text/plain; content_by_lua_block { ngx.print("or-bench-lua") } }
  }
}
EOF

log "启动被测实例 (端口 $PORT)"
"$NGINX" -p "$WORK/" > "$WORK/nginx.out" 2>&1 &
NGX_PID=$!
READY=0
for _ in $(seq 1 50); do
  if "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 1).close()" 2>/dev/null; then READY=1; break; fi
  if ! kill -0 "$NGX_PID" 2>/dev/null; then break; fi
  sleep 0.2
done
if [ "$READY" != "1" ]; then
  echo "错误: 被测实例未就绪" >&2
  cat "$WORK/nginx.out" >&2 || true
  cat "$WORK/logs/error.log" >&2 || true
  exit 1
fi

# run_scenario <显示名> <路径>: ab 压测并输出 RPS
run_scenario() {
  local name="$1" path="$2" rps
  log "场景 $name (${DUR}s)"
  # -k keepalive; ab 在时限结束后输出统计
  ab -q -k -t "$DUR" -c 8 "http://127.0.0.1:$PORT$path" > "$WORK/ab.out" 2>/dev/null || true
  rps="$(sed -n 's/^Requests per second:    \([0-9.]*\).*/\1/p' "$WORK/ab.out" | head -1)"
  [ -n "$rps" ] || { echo "错误: ab 未输出 RPS ($name)" >&2; exit 1; }
  echo "$name: $rps req/s" >&2
  echo "$rps"
}

RESULTS=""
MIN_SEEN=

add_result() { # <显示名> <RPS>
  RESULTS="$RESULTS
| $1 | $2 |"
  if [ -z "$MIN_SEEN" ] || awk "BEGIN{exit !($2 < $MIN_SEEN)}"; then MIN_SEEN=$2; fi
}

add_result "静态 64B (keepalive)" "$(run_scenario static /s64)"
add_result "Lua hello (keepalive)" "$(run_scenario lua /lua)"

kill "$NGX_PID" 2>/dev/null || true
NGX_PID=

# ---------- 输出结果 ----------
log "写入 $OUT"
{
  echo "### $PLATFORM-$ARCH"
  echo
  echo "- 压测: ab -k -t ${DUR}s -c 8, worker_processes 2, nproc=$NPROC"
  echo "- 数字来自共享 CI runner, 波动较大, 仅供版本间粗对比, 不是严格基准"
  echo
  echo "| 场景 | 吞吐 (req/s) |"
  echo "| --- | --- |"
  echo "$RESULTS"
} > "$OUT"
cat "$OUT"

if awk "BEGIN{exit !($MIN_SEEN < $MIN_RPS)}"; then
  echo "错误: 最低吞吐 ${MIN_SEEN} req/s 低于残废检测下限 ${MIN_RPS} req/s, 构建产物疑似异常" >&2
  exit 1
fi

log "基准测试完成 (最低 ${MIN_SEEN} req/s)"
