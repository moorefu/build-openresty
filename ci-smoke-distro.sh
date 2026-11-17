#!/bin/bash
set -euo pipefail

# Usage: ci-smoke-distro.sh <包根目录>
# 在目标发行版容器内以 root 运行 (CI 的 smoke-distros job 用), 只依赖
# bash/coreutils/grep/sed, 不要求 perl/curl/python/openssl。
#
# 覆盖两个曾经只在 Debian/Ubuntu + root 下暴露的问题:
#   1) 编译期默认 user/group 为 nobody:nobody, 而 Debian 系只有 nogroup:
#      wrapper 必须自动探测并合并 user 指令 (含 -g 'daemon off;' 的调用姿势)
#   2) 默认 conf 的 lua_package_cpath 必须包含包内 lualib/, 否则 cjson 等
#      C 模块在干净容器里 require 失败 (";;" 兜底的编译期绝对路径不存在)

ROOT="${1:?Usage: $0 <包根目录>}"
ROOT="$(cd "$ROOT" && pwd)"
NGINX="$ROOT/bin/openresty"
PORT_HTTP=8080
PORT_CJSON=18080
PID=""
WORK="$(mktemp -d /tmp/or-ci-smoke.XXXXXX)"

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  [ -f "$ROOT/nginx/logs/error.log" ] && cat "$ROOT/nginx/logs/error.log" >&2
  exit 1
}

[ -x "$NGINX" ] || fail "$NGINX 不存在或不可执行"

echo "==> [1/4] 默认 conf 语法检查 (root, 无 -g)"
"$NGINX" -t || fail "默认 conf 启动检查失败 (getgrnam?)"

echo "==> [2/4] 默认 conf + -g 'daemon off;' (容器 CMD 常见姿势)"
"$NGINX" -t -g 'daemon off;' || fail "-g 合并后启动检查失败"

echo "==> [3/4] 默认 conf 的 lua_package_cpath 含 lualib/"
grep -Fq 'lua_package_cpath "$prefix/../lualib/?.so;$prefix/../luajit/lib/?.so;;";' \
  "$ROOT/nginx/conf/nginx.conf" || fail "默认 conf 的 cpath 缺少 lualib/?.so"

echo "==> [4/4] 功能验证: 默认 conf 首页 + cjson (随包 lualib)"
cat > "$ROOT/nginx/conf/ci-smoke.conf" <<'EOF'
server {
    listen 18080;
    location = /cjson {
        default_type text/plain;
        content_by_lua_block {
            local cjson = require "cjson"
            ngx.print("cjson-ok")
        }
    }
}
EOF
# include 的相对路径按主 conf 所在目录解析 (conf_prefix)
sed -i '/^http {/a\    include ci-smoke.conf;' "$ROOT/nginx/conf/nginx.conf"

"$NGINX" -g 'daemon off;' > "$WORK/nginx.out" 2>&1 &
PID=$!

ready=0
for _ in $(seq 1 50); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT_CJSON") 2>/dev/null; then
    ready=1
    break
  fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.2
done
[ "$ready" = 1 ] || { cat "$WORK/nginx.out" >&2; fail "端口 $PORT_CJSON 未就绪"; }

http_get() {
  local port="$1" path="$2"
  ( exec 3<>"/dev/tcp/127.0.0.1/$port" || exit 1
    printf 'GET %s HTTP/1.0\r\nHost: localhost\r\n\r\n' "$path" >&3
    cat <&3
  )
}

body="$(http_get "$PORT_CJSON" /cjson)"
case "$body" in
  *cjson-ok*) ;;
  *) fail "cjson 断言失败: $body" ;;
esac

head="$(http_get "$PORT_HTTP" /)"
case "$head" in
  *" 200 "*) ;;
  *) fail "默认 conf 首页未返回 200: $head" ;;
esac

echo "PASS: 默认 conf + nobody/nogroup 自适应 + lualib cpath"
