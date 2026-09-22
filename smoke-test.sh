#!/bin/bash
set -e

# Usage: smoke-test.sh <包根目录>
# <包根目录>: 便携包解压后的 openresty-<版本>/ 目录
#
# 冒烟测试编排: 用包内 bin/openresty (便携 wrapper) 起多组不同配置的实例,
# 逐一做 HTTP 级断言。任何一组失败即退出非零 (发布门禁)。
#   默认 conf    → 包内自带 conf 原样启动 (验证 resty.core 经 $prefix 相对
#                  lua_package_path 加载 —— 便携化改动的核心点)
#   静态实例     → 首页 200 + 内容断言 + stub_status
#   Lua 实例     → content_by_lua 动态内容 (同时验证 LuaJIT 动态库加载)
#   TLS 实例     → 自签证书 https 200
#   代理实例     → ngx_http_proxy_connect_module 的 CONNECT 正向代理隧道
#   resty CLI    → bin/resty 按脚本位置定位 nginx (验证便携补丁)

ROOT="${1:?Usage: $0 <包根目录>}"
ROOT="$(cd "$ROOT" && pwd)"
NGINX="$ROOT/bin/openresty"

log() { echo "==> $*"; }

[ -x "$NGINX" ] || { echo "错误: $NGINX 不存在或不可执行" >&2; exit 1; }

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  PY="$(ls /opt/python/cp3*/bin/python3 2>/dev/null | head -1 || true)"
fi
[ -n "$PY" ] || { echo "错误: 找不到 python, 无法探测端口" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "错误: 找不到 curl" >&2; exit 1; }

OPENSSL_BIN="${OPENSSL_BIN:-$(command -v openssl || true)}"
[ -n "$OPENSSL_BIN" ] || { echo "错误: 找不到 openssl 命令, 无法生成 TLS 测试证书" >&2; exit 1; }

P_DEF=80; P_HTTP=12411; P_LUA=12412; P_TLS=12413; P_CONN=12414
WORK="$(mktemp -d /tmp/or-smoke.XXXXXX)"
# mktemp 创建的目录为 700, worker 默认以 nobody 运行会读不到 prefix 内文件
chmod 755 "$WORK"
PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  # 默认 conf 场景是 daemon 模式, 经 pid 文件停止
  "$NGINX" -p "$ROOT/nginx/" -s quit >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

wait_port() {
  for _ in $(seq 1 50); do
    if "$PY" -c "import socket; socket.create_connection(('127.0.0.1', $1), 1).close()" 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  echo "错误: 端口 $1 的实例 10 秒内未就绪" >&2
  return 1
}

# make_prefix <名字>: 生成独立 prefix 目录 (conf/logs/html), 输出目录路径
make_prefix() {
  local d="$WORK/$1"
  mkdir -p "$d/conf" "$d/logs" "$d/html"
  echo "or-smoke-$1" > "$d/html/index.html"
  echo "$d"
}

# start_nginx <名字> <端口> [额外 server 配置...]: 写 conf 并以 wrapper 启动
# wrapper 按 -p 定位, conf 中相对路径 (html/logs) 均相对该 prefix;
# daemon off 保证 $! 即 master 进程, 便于清理
start_nginx() {
  local name="$1" port="$2"; shift 2
  local d; d="$(make_prefix "$name")"
  cat > "$d/conf/nginx.conf" <<EOF
daemon off;
worker_processes 1;
error_log logs/error.log warn;
pid logs/nginx.pid;
events { worker_connections 128; }
http {
  $LUA_PATH_CONF
  access_log off;
  server {
    listen 127.0.0.1:$port${LISTEN_EXTRA:-};
    $*
  }
}
EOF
  log "启动实例 $name (端口 $port)"
  "$NGINX" -p "$d/" > "$WORK/$name.out" 2>&1 &
  PIDS+=($!)
  if ! wait_port "$port"; then
    echo "----- 实例输出 ($WORK/$name.out) -----" >&2
    cat "$WORK/$name.out" >&2 || true
    echo "----- 错误日志 ($d/logs/error.log) -----" >&2
    cat "$d/logs/error.log" >&2 || true
    return 1
  fi
  LAST_PREFIX="$d"
}

# http_get <url> [curl 参数...]: 断言 200 并输出 body
http_get() {
  local url="$1"; shift
  curl -sf "$@" "$url"
}

# 自定义 conf 的 Lua 搜索路径: 显式指向包内 (验证动态库/lua 库本身,
# 不依赖默认 conf 的注入)
LUA_PATH_CONF="lua_package_path \"$ROOT/lualib/?.lua;$ROOT/site/lualib/?.lua;;\";
  lua_package_cpath \"$ROOT/luajit/lib/?.so;;\";"

log "版本检查"
"$NGINX" -V 2>&1 | tail -1

# ---------- 默认 conf 实例: 包内 conf 原样启动 ----------
# 验证点: (1) 编译期绝对 prefix 无效时 conf/可定位 (wrapper -p);
# (2) 注入的 $prefix 相对 lua_package_path 能加载 resty.core (ngx_lua http
# 初始化阶段必需, 加载失败则 worker 无法服务)
log "冒烟: 默认 conf 启动 (resty.core 加载)"
rm -f "$ROOT/nginx/logs/error.log"
"$NGINX" -p "$ROOT/nginx/"
if ! wait_port "$P_DEF"; then
  echo "----- 错误日志 ($ROOT/nginx/logs/error.log) -----" >&2
  cat "$ROOT/nginx/logs/error.log" >&2 || true
  exit 1
fi
body="$(http_get "http://127.0.0.1:$P_DEF/")"
[ -n "$body" ] || { echo "错误: 默认 conf 首页为空" >&2; exit 1; }
if grep -q "failed to load" "$ROOT/nginx/logs/error.log" 2>/dev/null; then
  echo "错误: 默认 conf 下 resty.core 等 lua 模块加载失败:" >&2
  cat "$ROOT/nginx/logs/error.log" >&2
  exit 1
fi
"$NGINX" -p "$ROOT/nginx/" -s quit
log "默认 conf 实例已正常退出"

# ---------- 静态实例: 首页 + stub_status ----------
start_nginx static "$P_HTTP" 'location / { root html; }
    location = /status { stub_status; }'
log "冒烟: 静态首页 + stub_status"
body="$(http_get "http://127.0.0.1:$P_HTTP/")"
[ "$body" = "or-smoke-static" ] || { echo "错误: 静态首页内容不符: $body" >&2; exit 1; }
http_get "http://127.0.0.1:$P_HTTP/status" | grep -q 'Active connections:' \
  || { echo "错误: stub_status 输出异常" >&2; exit 1; }

# ---------- Lua 实例: content_by_lua (验证 LuaJIT 动态库) ----------
start_nginx lua "$P_LUA" 'default_type text/plain;
    location = /hello { content_by_lua_block { ngx.print("hello-lua-" .. 21 * 2) } }'
log "冒烟: Lua content_by_lua"
body="$(http_get "http://127.0.0.1:$P_LUA/hello")"
[ "$body" = "hello-lua-42" ] || { echo "错误: Lua 输出不符: $body" >&2; exit 1; }

# ---------- TLS 实例 ----------
TLSDIR="$WORK/tls"
mkdir -p "$TLSDIR"
MSYS2_ARG_CONV_EXCL='/CN=localhost' \
"$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$TLSDIR/key.pem" -out "$TLSDIR/cert.pem" \
  -subj "/CN=localhost" >/dev/null 2>&1
# listen 行需要 ssl 参数 (LISTEN_EXTRA 由 start_nginx 拼接)
LISTEN_EXTRA=" ssl"
start_nginx tls "$P_TLS" 'ssl_certificate '"$TLSDIR"'/cert.pem;
    ssl_certificate_key '"$TLSDIR"'/key.pem;
    location / { root html; }'
unset LISTEN_EXTRA
log "冒烟: TLS"
body="$(http_get "https://127.0.0.1:$P_TLS/" -k)"
[ "$body" = "or-smoke-tls" ] || { echo "错误: TLS 首页内容不符: $body" >&2; exit 1; }

# ---------- CONNECT 正向代理实例 ----------
# proxy_connect 模块的 CONNECT 隧道: 用 curl --proxytunnel 强制 CONNECT 方式
# 经代理访问静态实例, 断言穿透后内容一致
NS="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
[ -n "$NS" ] || NS="8.8.8.8"
start_nginx conn "$P_CONN" 'resolver '"$NS"';
    proxy_connect;
    proxy_connect_allow all;
    proxy_connect_connect_timeout 5s;'
log "冒烟: CONNECT 正向代理隧道"
body="$(http_get "http://127.0.0.1:$P_HTTP/" --proxytunnel -x "http://127.0.0.1:$P_CONN")"
[ "$body" = "or-smoke-static" ] || { echo "错误: CONNECT 隧道内容不符: $body" >&2; exit 1; }

# ---------- resty CLI ----------
# 验证便携补丁: resty 按自身位置定位 nginx, 并注入包内 lua 搜索路径
log "冒烟: resty CLI"
out="$("$ROOT/bin/resty" -e 'io.write("resty-ok")')"
[ "$out" = "resty-ok" ] || { echo "错误: resty CLI 输出不符: $out" >&2; exit 1; }

log "冒烟测试全部通过"
