#!/bin/bash
set -e

# Usage: ./build-openresty.sh <version> [openssl-ver] [pcre-ver] [zlib-ver] [arch]
# Example: ./build-openresty.sh 1.31.1.1 3.5.6 10.47 1.3.2 x86_64
#
# 在 manylinux2014 (glibc 2.17) 容器内运行, 构建便携的 OpenResty:
# OpenSSL/PCRE2/zlib/LuaJIT 全部动态链接, 对应 .so 随包分发 ——
# OpenSSL/PCRE2/zlib 位于包内 lib/, LuaJIT 位于包内 luajit/lib/,
# nginx 与 luajit 解释器的 rpath 用 patchelf 改写为 $ORIGIN 相对路径,
# 解压到任意目录即用, 目标机器只需 glibc >= 2.17, 无需安装任何依赖库。
# 产出 openresty-<版本>-linux-glibc2.17-<架构>-openssl-<ssl版本>.tar.xz (+ .sha256),
# 包内顶层目录为纯版本名: openresty-<版本>/{bin,lib,nginx,luajit,lualib,site}。
#
# 内置 ngx_http_proxy_connect_module（CONNECT 正向代理支持），
# 可用环境变量 PROXY_CONNECT_VER / PROXY_CONNECT_PATCH 覆盖模块版本与补丁。
#
# 便携化的打包期改写:
#   1. nginx/luajit 二进制 rpath -> $ORIGIN 相对路径 (patchelf)
#   2. bin/resty 打 patches/resty-cli-portable.patch: 还原上游 FindBin 便携
#      路径推导, 并注入按脚本位置定位的 lua 模块搜索路径 (上游依赖编译进
#      二进制的 LUA_DEFAULT_PATH 绝对路径, 便携包中失效)
#   3. bin/openresty 由绝对路径 symlink 替换为按脚本位置推导的 wrapper
#   4. 包内默认 nginx.conf 注入 lua_package_path ($prefix 相对形式, ngx_lua
#      原生支持 $prefix 运行时展开)
# 运行姿势: ./bin/openresty (自动以包内 nginx/ 为 prefix), 或
# ./nginx/sbin/nginx -p <包根>/nginx/ (nginx 编译进二进制的默认 prefix
# 是构建期的 /usr/local/openresty, 直接裸跑不带 -p 无法定位 conf)。

VERSION="${1:?Usage: $0 <version> [openssl-ver] [pcre-ver] [zlib-ver] [arch]}"
OS_VER="${2:-3.5.6}"
PCRE_VER="${3:-10.47}"
ZLIB_VER="${4:-1.3.2}"
ARCH="${5:-$(uname -m)}"
PREFIX=/usr/local/openresty   # 构建期前缀(绝对路径), 打包时转便携

# ngx_http_proxy_connect_module 版本。
PROXY_CONNECT_VER="${PROXY_CONNECT_VER:-v0.0.7}"
# GitHub archive tarball 的顶层目录会去掉 tag 名前导的 v（v0.0.7 -> 0.0.7）
PROXY_CONNECT_DIR="ngx_http_proxy_connect_module-${PROXY_CONNECT_VER#v}"

# 本脚本所在目录（patches/ 存放 nginx 1.31+ 的适配补丁与 resty 便携补丁）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 补丁选择：
#   nginx >= 1.31（OpenResty 1.31.x+）：核心已内置 CONNECT 请求行解析，
#   需使用仓库 patches/ 下的适配补丁（proxy_connect_1311.patch）；
#   更早版本使用模块自带补丁（proxy_connect_rewrite_102101.patch，支持 1.21.1 ~ 1.29.x）。
NGINX_VER="${VERSION%.*}"
if [ "$(printf '%s\n' "${NGINX_VER}" "1.31" | sort -V | head -1)" = "1.31" ]; then
    PROXY_CONNECT_PATCH="${PROXY_CONNECT_PATCH:-proxy_connect_1311.patch}"
    PROXY_CONNECT_NEW_NGINX=1
else
    PROXY_CONNECT_PATCH="${PROXY_CONNECT_PATCH:-proxy_connect_rewrite_102101.patch}"
    PROXY_CONNECT_NEW_NGINX=0
fi

DEPS=/tmp/or-deps            # 动态依赖的编译安装前缀
NPROC=$(nproc)

log() { echo "==> $*"; }

# 源码包缓存: cache/ 已有则直接复用(便于离线/本地构建), CI 冷启动自动下载
CACHE_DIR="${CACHE_DIR:-$SCRIPT_DIR/cache}"
mkdir -p "$CACHE_DIR"
download() {
  local url="$1"
  local out="${2:-$(basename "$url")}"
  if [ -s "$CACHE_DIR/$out" ]; then
    echo "==> Cache hit: $CACHE_DIR/$out"
    cp "$CACHE_DIR/$out" "$out"
  else
    echo "==> Downloading $url"
    curl -fsSL "$url" -o "$CACHE_DIR/$out" && cp "$CACHE_DIR/$out" "$out"
  fi
}

# manylinux2014: 启用 devtoolset (新版 GCC, 仍以 glibc 2.17 为链接基线)
# enable 脚本引用未定义变量, 需临时关闭 nounset
for dts in /opt/rh/devtoolset-*/enable; do
  if [ -f "$dts" ]; then set +u; . "$dts"; set -u; break; fi
done

log "安装构建工具"
# ab (httpd-tools): L2 基准压测工具
# 注意 patchelf 不在 yum 列表: aarch64 仓库无此包, yum 会因缺名整批中止
yum install -y curl pkgconfig perl-core xz httpd-tools || true
# patchelf (打包时把 rpath 改写为 $ORIGIN 相对路径):
# x86_64/aarch64 镜像均预装; 若无则下载官方二进制 (glibc 2.17 可运行),
# 二进制异常时再源码编译兜底
if ! command -v patchelf >/dev/null 2>&1; then
  (
    cd /tmp
    rm -rf patchelf-bin && mkdir patchelf-bin
    download "https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-$ARCH.tar.gz"
    tar -xzf "patchelf-0.18.0-$ARCH.tar.gz" -C patchelf-bin
    if ./patchelf-bin/bin/patchelf --version >/dev/null 2>&1; then
      log "安装官方 patchelf 二进制"
      install -m 755 patchelf-bin/bin/patchelf /usr/local/bin/patchelf
    else
      log "官方 patchelf 二进制不可运行, 源码编译"
      download "https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0.tar.gz"
      tar -xzf patchelf-0.18.0.tar.gz
      cd patchelf-0.18.0
      ./configure --prefix=/usr/local
      make -j"$NPROC"
      make install
    fi
  )
fi
command -v patchelf >/dev/null 2>&1 || { echo "错误: 需要 patchelf" >&2; exit 1; }

# OpenSSL 3.x 的 Configure 额外依赖 IPC::Cmd/Text::Template/Time::Piece(epel 提供)。
# 注意: CI 中先运行了 ci-fix-yum-repos.sh 修复 CentOS7 EOL 源; 本地构建若
# yum 失败, 参照该脚本换源。EPEL7 已 EOL, 源切到阿里云 epel-archive。
if [ "${OS_VER%%.*}" = "3" ]; then
  yum install -y epel-release || true
  if [ -f /etc/yum.repos.d/epel.repo ]; then
    sed -i -e 's|^mirrorlist=|#mirrorlist=|' \
           -e 's|^#baseurl=|baseurl=|' \
           -e 's|download.fedoraproject.org/pub/epel/7|mirrors.aliyun.com/epel-archive/7|g' \
           -e 's|dl.fedoraproject.org/pub/epel/7|mirrors.aliyun.com/epel-archive/7|g' \
           /etc/yum.repos.d/epel.repo || true
  fi
  yum install -y perl-devel perl-IPC-Cmd perl-Text-Template perl-Time-Piece || true
  # OpenSSL 3.5+ 要求 Text::Template >= 1.46, EPEL7 仓库只有 1.45,
  # 不满足时从 CPAN 镜像装单文件模块兜底
  if ! perl -MText::Template -e 'exit(($Text::Template::VERSION >= 1.46) ? 0 : 1)' 2>/dev/null; then
    log "安装 Text::Template >= 1.46 (CPAN 单文件模块)"
    (
      cd /tmp
      download "https://mirrors.aliyun.com/CPAN/authors/id/M/MJ/MJD/Text-Template-1.46.tar.gz"
      tar -xzf Text-Template-1.46.tar.gz
      install -D -m 644 Text-Template-1.46/lib/Text/Template.pm \
        /usr/share/perl5/vendor_perl/Text/Template.pm
    )
  fi
fi

# ---------- 动态依赖: OpenSSL / PCRE2 / zlib (随包分发) ----------
mkdir -p "$DEPS"
cd "$DEPS"

# ---------- 动态 OpenSSL ----------
if [ ! -f "$DEPS/openssl/lib/libssl.so" ]; then
  log "编译动态 OpenSSL $OS_VER"
  OPENSSL_URL="https://www.openssl.org/source/openssl-${OS_VER}.tar.gz"
  [ "${OS_VER%%.*}" = "3" ] && \
    OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OS_VER}/openssl-${OS_VER}.tar.gz"
  download "$OPENSSL_URL"
  tar -xzf "openssl-$OS_VER.tar.gz"
  cd "openssl-$OS_VER"
  ./Configure "linux-$ARCH" shared no-tests \
    --prefix="$DEPS/openssl" --openssldir="$DEPS/openssl" --libdir=lib
  make -j"$NPROC"
  make install_sw
  cd "$DEPS"
fi

# ---------- 动态 PCRE2 ----------
if [ ! -f "$DEPS/pcre2/lib/libpcre2-8.so" ]; then
  log "编译动态 PCRE2 $PCRE_VER"
  download "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VER}/pcre2-${PCRE_VER}.tar.gz"
  tar -xzf "pcre2-$PCRE_VER.tar.gz"
  cd "pcre2-$PCRE_VER"
  ./configure --enable-shared --disable-static --enable-jit --prefix="$DEPS/pcre2"
  make -j"$NPROC"
  make install
  cd "$DEPS"
fi

# ---------- 动态 zlib ----------
if [ ! -f "$DEPS/zlib/lib/libz.so" ]; then
  log "编译动态 zlib $ZLIB_VER"
  download "https://zlib.net/zlib-${ZLIB_VER}.tar.gz"
  tar -xzf "zlib-$ZLIB_VER.tar.gz"
  cd "zlib-$ZLIB_VER"
  ./configure --shared --prefix="$DEPS/zlib"
  make -j"$NPROC"
  make install
  cd "$DEPS"
fi

# ---------- OpenResty ----------
log "编译 OpenResty ${VERSION} (${ARCH})"
download "https://openresty.org/download/openresty-${VERSION}.tar.gz"
download "https://github.com/chobits/ngx_http_proxy_connect_module/archive/refs/tags/${PROXY_CONNECT_VER}.tar.gz" \
  "proxy-connect-${PROXY_CONNECT_VER}.tar.gz"
tar xzf "openresty-${VERSION}.tar.gz"
tar xzf "proxy-connect-${PROXY_CONNECT_VER}.tar.gz"
cd "openresty-${VERSION}"

# OpenSSL/PCRE2/zlib 不再走 OpenResty 的源码内部编译(--with-openssl=DIR 等,
# 那是静态链接), 而是链接 $DEPS 下预编译的动态库: nginx configure 自动检测
# 系统/指定路径下的 -lssl/-lcrypto/-lpcre2-8/-lz。链接期 rpath 指向 $DEPS
# 绝对路径(构建树即可直接运行测试), 打包时统一 patchelf 改写为 $ORIGIN。
# LuaJIT 仍由 OpenResty 内部构建(动态), rpath 由其 configure 自动加。
CC_OPTS="-I$DEPS/openssl/include -I$DEPS/pcre2/include -I$DEPS/zlib/include"
LD_OPTS="-L$DEPS/openssl/lib -L$DEPS/pcre2/lib -L$DEPS/zlib/lib \
    -Wl,-rpath,$DEPS/openssl/lib -Wl,-rpath,$DEPS/pcre2/lib -Wl,-rpath,$DEPS/zlib/lib"

./configure \
  --prefix="$PREFIX" \
  --with-cc-opt="$CC_OPTS" \
  --with-ld-opt="$LD_OPTS" \
  --with-pcre-jit \
  --with-ipv6 \
  --with-threads \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_realip_module \
  --with-http_stub_status_module \
  --with-http_gzip_static_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-luajit \
  --add-module="$(pwd)/../${PROXY_CONNECT_DIR}" \
  -j"$NPROC"

# 给 OpenResty 解压出的 nginx 核心打补丁，启用 CONNECT 请求处理。
# 必须在 ./configure 之后、make 之前执行（模块官方构建流程）。
# nginx 核心目录用 glob 探测（如 build/nginx-1.31.1/），不能硬编码版本号。
NGINX_SRC="$(pwd)/$(find build -maxdepth 1 -type d -name 'nginx-*' | head -1)"
echo "==> Patching nginx core at ${NGINX_SRC} (${PROXY_CONNECT_PATCH})"
if [ "${PROXY_CONNECT_NEW_NGINX}" = "1" ]; then
  patch -d "${NGINX_SRC}" -p1 < "${SCRIPT_DIR}/patches/${PROXY_CONNECT_PATCH}"
  # nginx 1.31+ 的 CONNECT 准入由核心 allow_connect 控制，需同步修改模块源码
  echo "==> Patching proxy_connect module for nginx 1.31+"
  patch -d "$(pwd)/../${PROXY_CONNECT_DIR}" -p1 \
    < "${SCRIPT_DIR}/patches/proxy_connect_module_1311.patch"
else
  patch -d "${NGINX_SRC}" -p1 < "$(pwd)/../${PROXY_CONNECT_DIR}/patch/${PROXY_CONNECT_PATCH}"
fi
echo "==> Patch done"

# resty CLI 便携补丁: configure 已把上游的 'my $nginx_path;' patch 成硬编码
# 绝对路径, 且上游默认 lua 搜索路径依赖编译进二进制的 LUA_DEFAULT_PATH ——
# 两者在便携包(解压到任意位置)中均失效。补丁还原 FindBin 推导并注入按脚本
# 位置定位的 lua_package_path。
RESTY_CLI_DIR="$(find build -maxdepth 1 -type d -name 'resty-cli-*' | head -1)"
echo "==> Patching resty CLI for portability (${RESTY_CLI_DIR})"
patch -d "${RESTY_CLI_DIR}" -p1 --fuzz=3 \
  < "${SCRIPT_DIR}/patches/resty-cli-portable.patch"

make -j"$NPROC"
make install DESTDIR="$(pwd)/install"

# ---------- 便携化打包 ----------
# 包内顶层目录用纯版本名 openresty-<version>, 压缩包文件名保留平台/依赖版本后缀
log "便携化打包"
DIST="openresty-$VERSION-linux-glibc2.17-$ARCH-openssl-$OS_VER"
INNER="openresty-$VERSION"
STAGE="/tmp/.or-stage.$$"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -a "install$PREFIX" "$STAGE/$INNER"

# 1) 依赖 .so 打进包内 lib/ (cp -P 保留 soname 符号链接链)
mkdir -p "$STAGE/$INNER/lib"
for libdir in "$DEPS/openssl/lib" "$DEPS/pcre2/lib" "$DEPS/zlib/lib"; do
  cp -P "$libdir"/*.so.* "$STAGE/$INNER/lib/" 2>/dev/null || true
done
# libcrypt (libxcrypt) 随包: nginx 核心 auth_basic (ngx_user.c 的 crypt_r)
# 直接依赖 libcrypt.so.2, manylinux 镜像的 libxcrypt 装在 /usr/local/lib,
# 目标机器 glibc 2.17 系统未必有。打进包内 lib/ (nginx 的 rpath 覆盖该目录)
CRYPT_NEEDED="$(readelf -d "$STAGE/$INNER/nginx/sbin/nginx" 2>/dev/null \
  | sed -n 's/.*Shared library: \[\(libcrypt[^]]*\)\].*/\1/p' | sort -u)"
if [ -n "$CRYPT_NEEDED" ]; then
  for soname in $CRYPT_NEEDED; do
    CRYPT_PATH="$(ldd "$STAGE/$INNER/nginx/sbin/nginx" 2>/dev/null \
      | awk -v n="$soname" '$1==n && $2=="=>" {print $3; exit}')"
    [ -n "$CRYPT_PATH" ] && [ -f "$CRYPT_PATH" ] || {
      echo "错误: nginx 依赖 $soname 但构建机上无法解析" >&2; exit 1; }
    log "随包分发 $soname <- $CRYPT_PATH"
    cp -L "$CRYPT_PATH" "$STAGE/$INNER/lib/$soname"
  done
fi

# 2) rpath 改写为 $ORIGIN 相对路径:
#    nginx/sbin/nginx  -> ../../lib:../../luajit/lib (依赖库 + LuaJIT)
#    luajit/bin/luajit -> ../lib (LuaJIT 动态库)
#    包内 lib/*.so     -> $ORIGIN (lib 内互找, 如 libssl 找 libcrypto/libcrypt)
#    (构建期 rpath 是 $DEPS/$PREFIX 绝对路径, 这里只在构建机上改写一次,
#    用户侧无任何工具要求)
patchelf --set-rpath '$ORIGIN/../../lib:$ORIGIN/../../luajit/lib' \
  "$STAGE/$INNER/nginx/sbin/nginx"
patchelf --set-rpath '$ORIGIN/../lib' "$STAGE/$INNER/luajit/bin/luajit"
for so in "$STAGE/$INNER/lib/"*.so.*; do
  [ -f "$so" ] && patchelf --set-rpath '$ORIGIN' "$so"
done

# 兜底: 安装树里其余 ELF 的动态段不允许残留构建期绝对路径
for elf in $(find "$STAGE/$INNER" -type f | while read -r f; do
    file -b "$f" 2>/dev/null | grep -q 'ELF' && echo "$f"; done); do
  if readelf -d "$elf" 2>/dev/null | grep -qE "$PREFIX|$DEPS"; then
    echo "错误: $elf 的动态段仍含构建期绝对路径" >&2
    exit 1
  fi
done

# 3) bin/openresty 是指向 $PREFIX 绝对路径的 symlink, 替换为便携 wrapper
# (先清掉 patch 命令留在 bin/ 的 .orig 备份, 内含硬编码路径且不该发布)
rm -f "$STAGE/$INNER/bin/"*.orig
rm -f "$STAGE/$INNER/bin/openresty"
cat > "$STAGE/$INNER/bin/openresty" <<'EOF'
#!/bin/sh
# 便携 wrapper: 按脚本自身位置定位包根, 以包内 nginx/ 为 prefix 启动,
# 保证任意解压位置下 conf/logs/temp 路径均正确
or_root=$(cd "$(dirname "$0")/.." && pwd)
exec "$or_root/nginx/sbin/nginx" -p "$or_root/nginx/" "$@"
EOF
chmod 755 "$STAGE/$INNER/bin/openresty"

# 4) 默认 nginx.conf 注入 lua 模块搜索路径: ngx_lua 原生支持 $prefix 占位符
#    (运行时展开为 nginx prefix, 即 wrapper 传的 <包根>/nginx/)。
#    上游默认 conf 不含 lua_package_path, 依赖编译进二进制的
#    LUA_DEFAULT_PATH 绝对路径, 便携包中会因找不到 resty.core 而启动失败。
for conf in nginx.conf nginx.conf.default; do
  sed -i '/^http {/a\    lua_package_path "$prefix/../lualib/?.lua;$prefix/../site/lualib/?.lua;;";\n    lua_package_cpath "$prefix/../luajit/lib/?.so;;";' \
    "$STAGE/$INNER/nginx/conf/$conf"
done
grep -q 'lua_package_path' "$STAGE/$INNER/nginx/conf/nginx.conf" || {
  echo "错误: 默认 conf 注入 lua_package_path 失败" >&2; exit 1; }

# bin/ 下脚本不应引用构建期绝对前缀
if grep -rl "$PREFIX" "$STAGE/$INNER/bin/" >/dev/null 2>&1; then
  echo "错误: 以下脚本仍引用构建期前缀 $PREFIX:" >&2
  grep -rl "$PREFIX" "$STAGE/$INNER/bin/" >&2
  exit 1
fi

# strip 只做 ELF 二进制 (脚本/符号链接会被 strip 报错)
for elf in "$STAGE/$INNER/nginx/sbin/nginx" "$STAGE/$INNER/luajit/bin/luajit"; do
  strip --strip-all "$elf" 2>/dev/null || true
done

cat > "$STAGE/$INNER/README.txt" <<EOF
OpenResty $VERSION 便携版 (Linux $ARCH, glibc >= 2.17)

解压即用, 目标系统只需 glibc >= 2.17, 无需安装任何依赖库:
  - OpenSSL $OS_VER / PCRE2 $PCRE_VER / zlib $ZLIB_VER / LuaJIT 以动态链接
    方式随包分发 (lib/ 与 luajit/lib/), 二进制 rpath 指向包内目录
    (\$ORIGIN 相对路径, 不依赖系统安装)
  - 内置 ngx_http_proxy_connect_module (HTTP CONNECT 正向代理)

基本用法 (推荐, 自动定位包内 nginx/ 为 prefix):
  ./bin/openresty                     # 启动 (默认 conf 监听 80)
  ./bin/openresty -s reload|quit|stop # 信号控制
  ./bin/resty -e 'print("hello")'     # LuaJIT/resty CLI

直接调 nginx 二进制需显式指定 prefix:
  ./nginx/sbin/nginx -p \$PWD/nginx/

目录结构:
  bin/     openresty 启动 wrapper, resty CLI, opm 包管理器
  lib/     OpenSSL/PCRE2/zlib/libcrypt 动态库
  nginx/   nginx 核心 (sbin/nginx, conf/, html/, logs/)
  luajit/  LuaJIT 解释器与动态库
  lualib/  lua-resty-* 库
  site/    opm 安装目录 (lualib/pod/manifest)
EOF

# ---------- L0: 构建自检 ----------
log "L0 构建自检 (nginx -V / -t)"
"$STAGE/$INNER/bin/openresty" -V 2>&1
"$STAGE/$INNER/bin/openresty" -t

# ---------- 便携性验证 ----------
# 非系统的库必须解析到包内 (lib/ 或 luajit/lib/), 不允许解析到系统目录
# (否则目标机器上会缺库), 也不允许有 not found。
check_ldd() {
  local bin="$1"; shift
  local bad="" lib arrow path _rest p pre matched
  while read -r lib arrow path _rest; do
    case "$lib" in linux-vdso*|ld-linux*) continue ;; esac
    if [ "$arrow" = "=>" ] && [ "$path" != "not" ]; then
      p="$(realpath -m "$path" 2>/dev/null || echo "$path")"
    else
      [ "$path" = "not" ] && bad="$bad
$lib NOT_FOUND"
      continue
    fi
    case "$lib" in
      libc.so*|libpthread*|libdl*|libm.so*|librt*|libresolv*|libgcc_s*) continue ;;
    esac
    # 逐前缀判断 (case 的变量展开不会把 '|' 重新解释为模式分隔符)
    matched=0
    for pre in "$@"; do
      case "$p" in
        "$pre"/*) matched=1; break ;;
      esac
    done
    if [ "$matched" != 1 ]; then
      bad="$bad
$lib -> $p"
    fi
  done < <(ldd "$bin")
  if [ -n "$bad" ]; then
    echo "错误: $bin 存在系统目录依赖或缺失的动态库:" >&2
    echo "$bad" >&2
    return 1
  fi
}

log "检查动态依赖 (系统库只允许 glibc 家族, 其余必须来自包内)"
ldd "$STAGE/$INNER/nginx/sbin/nginx"
check_ldd "$STAGE/$INNER/nginx/sbin/nginx" \
  "$STAGE/$INNER/lib" "$STAGE/$INNER/luajit/lib"
check_ldd "$STAGE/$INNER/luajit/bin/luajit" \
  "$STAGE/$INNER/lib" "$STAGE/$INNER/luajit/lib"

# ---------- L1: 冒烟测试 ----------
# 多配置实例(默认conf/静态/Lua/TLS/CONNECT/resty)的 HTTP 级断言, 详见 smoke-test.sh
log "L1 冒烟测试 (默认conf/静态/Lua/TLS/CONNECT/resty)"
bash "$SCRIPT_DIR/smoke-test.sh" "$STAGE/$INNER"

# 冒烟会在包内 nginx/logs/ 留下日志, 打包前清掉
rm -f "$STAGE/$INNER/nginx/logs/"*.log 2>/dev/null || true

# ---------- L2: 基准测试 ----------
# ab 两场景吞吐, 结果写入 benchmark-<平台>-<架构>.txt (非门禁, 含残废检测)
log "L2 基准测试 (ab)"
bash "$SCRIPT_DIR/benchmark.sh" "$STAGE/$INNER"

# ---------- 压缩包 ----------
log "生成压缩包"
tar -C "$STAGE" -cJf "$DIST.tar.xz" "$INNER"
sha256sum "$DIST.tar.xz" > "$DIST.tar.xz.sha256"

# ---------- 解压场景验证 ----------
# 解包产物到任意临时目录再跑全套冒烟: rpath 应让 nginx/luajit 找到包内
# 动态库, resty/wrapper 应按新位置定位 nginx —— 用清空 LD_LIBRARY_PATH
# 防止构建环境的系统库掩盖便携性问题。同时断言 ldd 无系统目录依赖。
log "解压场景验证 (rpath + 屏蔽系统库路径)"
VERIFY="/tmp/.or-verify-unpack.$$"
rm -rf "$VERIFY"; mkdir -p "$VERIFY"
tar -xJf "$DIST.tar.xz" -C "$VERIFY"
check_ldd "$VERIFY/$INNER/nginx/sbin/nginx" \
  "$VERIFY/$INNER/lib" "$VERIFY/$INNER/luajit/lib" || {
  rm -rf "$VERIFY" "$STAGE"; exit 1; }
( cd "$VERIFY/$INNER" && env -u LD_LIBRARY_PATH \
    bash "$SCRIPT_DIR/smoke-test.sh" "$PWD" )
rm -rf "$VERIFY" "$STAGE"

# 输出移到工程根目录
mv "$DIST.tar.xz" "$DIST.tar.xz.sha256" "$SCRIPT_DIR/"
log "完成: $SCRIPT_DIR/$DIST.tar.xz"
