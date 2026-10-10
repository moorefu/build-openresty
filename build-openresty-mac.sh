#!/bin/bash
set -e

# Usage: ./build-openresty-mac.sh <version> [openssl-ver] [pcre-ver] [zlib-ver]
# Example: ./build-openresty-mac.sh 1.31.1.1 3.5.6 10.47 1.3.2
#
# 在 macOS (GitHub Actions macos-15 arm64 / macos-15-intel x86_64) 上构建便携
# OpenResty。与 Linux 版 (build-openresty.sh) 同一套便携化思路, 差异在 macOS
# 的动态库机制 (无 patchelf / 无 $ORIGIN, 对应手段是 install_name_tool):
#   1) OpenSSL/PCRE2/zlib 编译为 dylib, 随包分发在包内 lib/; LuaJIT dylib 由
#      OpenResty 内部构建, 位于包内 luajit/lib/;
#   2) 包内每个 dylib 的 install id 改写为 @loader_path/<名字>;
#   3) 所有 Mach-O (nginx/luajit 解释器/各 dylib) 对包内库的依赖引用逐个
#      改写为 @loader_path/<相对路径> —— 构建期这些引用是绝对路径
#      ($DEPS 下) 或相对路径 (OpenResty 给 LuaJIT 传 PREFIX=./luajit, dylib
#      install_name 是 ./luajit/lib/..., dyld 按 CWD 解析必然失效), 统一按
#      依赖的 basename 在包内索引定位后改写;
#   4) 删除链接期残留的绝对路径 LC_RPATH (依赖已 @loader_path 化, 不需要);
#   5) install_name_tool 改写会使代码签名失效, 全部重新 ad-hoc 签名
#      (arm64 二进制无有效签名会被内核直接拒绝执行)。
#   @loader_path 由 dyld 在运行时解析为"引用者自身所在目录", 与 Linux 的
#   $ORIGIN 等价: 解压到任意位置即用, 目标机器无需安装任何依赖库。
#
# 链接基线由 MACOSX_DEPLOYMENT_TARGET 控制 (默认 11.0, 即首个 arm64 版本;
# clang/OpenSSL/LuaJIT 均遵循该变量), 产出可在 macOS >= 11.0 上运行。
# 产出 openresty-<版本>-macos-<基线>-<架构>-openssl-<ssl版本>.tar.xz
# (+ .sha256), 包内顶层目录为纯版本名, 布局与 Linux 包一致。
#
# 内置 ngx_http_proxy_connect_module (CONNECT 正向代理); bin/openresty
# wrapper 替换与默认 conf 的 lua_package_path 注入等改写与 Linux 版相同,
# 见 build-openresty.sh 注释。
#
# 运行环境要求 (GitHub macOS runner 均预装): Xcode CLT (clang/make/perl/
# patch/otool/install_name_tool/codesign/file/tar), python3, curl; tar 无
# xz 支持时自动 brew 安装。脚本兼容系统自带 bash 3.2 (无关联数组等语法)。

VERSION="${1:?Usage: $0 <version> [openssl-ver] [pcre-ver] [zlib-ver]}"
OS_VER="${2:-3.5.6}"
PCRE_VER="${3:-10.47}"
ZLIB_VER="${4:-1.3.2}"
ARCH="$(uname -m)"
PREFIX=/usr/local/openresty   # 构建期前缀(绝对路径), 打包时转便携
MACOS_MIN="${MACOS_MIN:-11.0}"
export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

# ngx_http_proxy_connect_module 版本。
PROXY_CONNECT_VER="${PROXY_CONNECT_VER:-v0.0.7}"
PROXY_CONNECT_DIR="ngx_http_proxy_connect_module-${PROXY_CONNECT_VER#v}"

# 本脚本所在目录（patches/ 存放 nginx 1.31+ 的适配补丁与 resty 便携补丁）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 补丁选择: nginx >= 1.31 用仓库 patches/ 适配补丁, 更早版本用模块自带补丁。
# 纯算术比较, 不依赖 GNU sort -V (macOS 无)
NGINX_VER="${VERSION%.*}"
NGX_MAJ="${NGINX_VER%%.*}"
NGX_MIN="${NGINX_VER#*.}"; NGX_MIN="${NGX_MIN%%.*}"
if [ "$NGX_MAJ" -gt 1 ] || { [ "$NGX_MAJ" -eq 1 ] && [ "$NGX_MIN" -ge 31 ]; }; then
    PROXY_CONNECT_PATCH="${PROXY_CONNECT_PATCH:-proxy_connect_1311.patch}"
    PROXY_CONNECT_NEW_NGINX=1
else
    PROXY_CONNECT_PATCH="${PROXY_CONNECT_PATCH:-proxy_connect_rewrite_102101.patch}"
    PROXY_CONNECT_NEW_NGINX=0
fi

DEPS=/tmp/or-deps            # 动态依赖的编译安装前缀
NPROC="$(sysctl -n hw.ncpu)"
PY3="$(command -v python3 || command -v python || true)"

log() { echo "==> $*"; }

# ---------- 工具检查 ----------
for t in clang make perl patch curl otool install_name_tool codesign file; do
  command -v "$t" >/dev/null 2>&1 \
    || { echo "错误: 缺少 $t (需 Xcode Command Line Tools)" >&2; exit 1; }
done
[ -n "$PY3" ] || { echo "错误: 找不到 python3" >&2; exit 1; }

# sha256: macOS 无 sha256sum, 用 perl 自带的 shasum (输出格式相同)
sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
  else shasum -a 256 "$1"; fi
}

# tar.xz: 系统 bsdtar 自带 liblzma 时 -J 可用, 否则 brew 装 xz
if ! (echo probe | tar -cJf /tmp/.or-xz-probe.tar.xz -) >/dev/null 2>&1; then
  log "安装 xz (brew)"
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install xz
fi
rm -f /tmp/.or-xz-probe.tar.xz

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

# ---------- 动态依赖: OpenSSL / PCRE2 / zlib (随包分发) ----------
mkdir -p "$DEPS"
cd "$DEPS"

# ---------- 动态 OpenSSL ----------
if [ ! -e "$DEPS/openssl/lib/libssl.dylib" ]; then
  log "编译动态 OpenSSL $OS_VER"
  case "$ARCH" in
    arm64)  SSL_TARGET="darwin64-arm64-cc" ;;
    x86_64) SSL_TARGET="darwin64-x86_64-cc" ;;
    *) echo "错误: 不支持的架构 $ARCH" >&2; exit 1 ;;
  esac
  OPENSSL_URL="https://www.openssl.org/source/openssl-${OS_VER}.tar.gz"
  [ "${OS_VER%%.*}" = "3" ] && \
    OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OS_VER}/openssl-${OS_VER}.tar.gz"
  download "$OPENSSL_URL"
  tar -xzf "openssl-$OS_VER.tar.gz"
  cd "openssl-$OS_VER"
  ./Configure "$SSL_TARGET" shared no-tests \
    --prefix="$DEPS/openssl" --openssldir="$DEPS/openssl" --libdir=lib
  make -j"$NPROC"
  make install_sw
  cd "$DEPS"
fi

# ---------- 动态 PCRE2 ----------
if [ ! -e "$DEPS/pcre2/lib/libpcre2-8.dylib" ]; then
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
if [ ! -e "$DEPS/zlib/lib/libz.dylib" ]; then
  log "编译动态 zlib $ZLIB_VER"
  download "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz"
  tar -xzf "zlib-$ZLIB_VER.tar.gz"
  cd "zlib-$ZLIB_VER"
  ./configure --shared --prefix="$DEPS/zlib"
  make -j"$NPROC"
  make install
  cd "$DEPS"
fi

# ---------- OpenResty ----------
cd "$SCRIPT_DIR"
log "编译 OpenResty ${VERSION} (${ARCH}, macOS >= ${MACOS_MIN})"
download "https://openresty.org/download/openresty-${VERSION}.tar.gz"
download "https://github.com/chobits/ngx_http_proxy_connect_module/archive/refs/tags/${PROXY_CONNECT_VER}.tar.gz" \
  "proxy-connect-${PROXY_CONNECT_VER}.tar.gz"
tar xzf "openresty-${VERSION}.tar.gz"
tar xzf "proxy-connect-${PROXY_CONNECT_VER}.tar.gz"
cd "openresty-${VERSION}"

# 与 Linux 版一致: 依赖库走预编译动态库 (不用 --with-openssl=DIR 等源码静态
# 链接方式), nginx configure 自动检测 -lssl/-lcrypto/-lpcre2-8/-lz。
# macOS 不需要链接期 rpath: 构建过程不执行产物, 依赖引用在打包期统一改写。
CC_OPTS="-I$DEPS/openssl/include -I$DEPS/pcre2/include -I$DEPS/zlib/include"
LD_OPTS="-L$DEPS/openssl/lib -L$DEPS/pcre2/lib -L$DEPS/zlib/lib"

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

# 给 nginx 核心打 proxy_connect 补丁 (须在 ./configure 之后、make 之前)
NGINX_SRC="$(pwd)/$(find build -maxdepth 1 -type d -name 'nginx-*' | head -1)"
echo "==> Patching nginx core at ${NGINX_SRC} (${PROXY_CONNECT_PATCH})"
if [ "${PROXY_CONNECT_NEW_NGINX}" = "1" ]; then
  patch -d "${NGINX_SRC}" -p1 < "${SCRIPT_DIR}/patches/${PROXY_CONNECT_PATCH}"
  echo "==> Patching proxy_connect module for nginx 1.31+"
  patch -d "$(pwd)/../${PROXY_CONNECT_DIR}" -p1 \
    < "${SCRIPT_DIR}/patches/proxy_connect_module_1311.patch"
else
  patch -d "${NGINX_SRC}" -p1 < "$(pwd)/../${PROXY_CONNECT_DIR}/patch/${PROXY_CONNECT_PATCH}"
fi
echo "==> Patch done"

# resty CLI 便携补丁 (还原 FindBin 推导 + 注入按脚本位置定位的 lua 搜索路径)
RESTY_CLI_DIR="$(find build -maxdepth 1 -type d -name 'resty-cli-*' | head -1)"
echo "==> Patching resty CLI for portability (${RESTY_CLI_DIR})"
patch -d "${RESTY_CLI_DIR}" -p1 --fuzz=3 \
  < "${SCRIPT_DIR}/patches/resty-cli-portable.patch"

make -j"$NPROC"
make install DESTDIR="$(pwd)/install"

# ---------- 便携化打包 ----------
log "便携化打包"
DIST="openresty-$VERSION-macos-$MACOS_MIN-$ARCH-openssl-$OS_VER"
INNER="openresty-$VERSION"
STAGE="/tmp/.or-stage.$$"
PKG="$STAGE/$INNER"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -a "install$PREFIX" "$PKG"

# 1) 依赖 dylib 打进包内 lib/ (cp -P 保留符号链接链); 拷贝失败即中止
mkdir -p "$PKG/lib"
for libdir in "$DEPS/openssl/lib" "$DEPS/pcre2/lib" "$DEPS/zlib/lib"; do
  ls "$libdir"/*.dylib >/dev/null 2>&1 \
    || { echo "错误: $libdir 下没有 dylib" >&2; exit 1; }
  cp -P "$libdir"/*.dylib "$PKG/lib/"
done
find "$PKG/lib" -maxdepth 1 -name '*.dylib' -print -quit | grep -q . \
  || { echo "错误: 包内 lib/ 为空" >&2; exit 1; }

# 2) 包内 dylib 索引: basename -> 包内相对路径 (依赖改写按 basename 定位)。
#    符号链接也要收录: LuaJIT 安装的真实文件名带完整版本号
#    (libluajit-5.1.2.1.ROLLING.dylib), 而 nginx 记录的依赖名是不带版本
#    尾巴的 SONAME 链接 (libluajit-5.1.2.dylib), 改写须指向链接名
IDX="$(mktemp /tmp/or-machoidx.XXXXXX)"
find "$PKG" \( -type f -o -type l \) -name '*.dylib' | while read -r f; do
  printf '%s\t%s\n' "${f##*/}" "${f#$PKG/}" >> "$IDX"
done
[ -s "$IDX" ] || { echo "错误: 包内未找到任何 dylib" >&2; exit 1; }

macho_lookup() { awk -F'\t' -v b="$1" '$1==b{print $2; exit}' "$IDX"; }
# python 算相对路径 (bash 3.2 无关联数组, 也不手搓 relpath)
relpath() {
  "$PY3" -c 'import os.path,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$2"
}
otool_deps() {
  otool -L "$1" | tail -n +2 \
    | sed -e 's/(.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}
otool_rpaths() {
  otool -l "$1" \
    | awk '/cmd LC_RPATH/{f=1;next} f&&/path /{sub(/^ *path /,""); sub(/ *\(offset.*/,""); print; f=0}'
}

fix_macho() {  # <file>: 依赖引用与 rpath 便携化改写
  local f="$1" rel dir dep base target newp rp
  rel="${f#$PKG/}"; dir="$(dirname "$rel")"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      # 系统库与已相对化的引用不动 (未改写问题由 verify_macho 拦截)
      /System/*|/usr/lib/*|@loader_path/*|@executable_path/*|@rpath/*) continue ;;
    esac
    base="${dep##*/}"
    target="$(macho_lookup "$base")"
    if [ -z "$target" ]; then
      echo "错误: ${f#$PKG/} 依赖 $dep, 既非系统库也不在包内" >&2
      return 1
    fi
    newp="@loader_path/$(relpath "$target" "$dir")"
    [ "$dep" = "$newp" ] && continue
    install_name_tool -change "$dep" "$newp" "$f"
  done < <(otool_deps "$f")
  # 删除残留的绝对路径 LC_RPATH (依赖已 @loader_path 化, 无需 rpath)
  while IFS= read -r rp; do
    [ -n "$rp" ] || continue
    case "$rp" in @*) continue ;; esac
    install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null || true
  done < <(otool_rpaths "$f")
}

# Mach-O 判定: 排除 ar 静态库 (file 对 .a 可能报 "Mach-O ... ar archive",
# 而 codesign/otool -L 对静态库会失败); fat 文件的架构描述在后续行, 只看首行
is_macho() {
  local t; t="$(file -b "$1" 2>/dev/null | head -1)"
  case "$t" in
    *Mach-O*)
      case "$t" in *archive*) return 1 ;; *) return 0 ;; esac ;;
    *) return 1 ;;
  esac
}

log "改写 Mach-O load commands (@loader_path 便携化)"
# 先统一改写包内 dylib 的 install id
find "$PKG" -type f -name '*.dylib' | while read -r f; do
  install_name_tool -id "@loader_path/${f##*/}" "$f"
done
# 再逐个 Mach-O 改写依赖引用 / 清 rpath, 并重新 ad-hoc 签名
# (install_name_tool 的任何改写都会使原签名失效, arm64 下必须重签才能执行)
find "$PKG" -type f | while read -r f; do
  if is_macho "$f"; then
    echo "  -> ${f#$PKG/}"
    fix_macho "$f"
    codesign -f -s - "$f" >/dev/null 2>&1
  fi
done

# 3) Mach-O 便携性验证 (对应 Linux 版的 check_ldd):
#    - load commands 不得残留构建期路径
#    - 依赖只允许系统库 (/System, /usr/lib) 与可解析到包内文件的 @loader_path
#    - 部署基线不得高于 MACOS_MIN (否则低版本系统无法加载)
verify_macho() {
  local f="$1" rel dir dep res minos bad=0
  rel="${f#$PKG/}"; dir="$(dirname "$rel")"
  for pat in "$DEPS" "$PREFIX" "$STAGE" "$SCRIPT_DIR/openresty-$VERSION" \
             /opt/homebrew /usr/local/opt /usr/local/Cellar; do
    if otool -l "$f" 2>/dev/null | grep -F -q "$pat"; then
      echo "错误: ${rel} 的 load commands 残留构建期路径 $pat" >&2
      bad=1
    fi
  done
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    case "$dep" in
      /System/*|/usr/lib/*) ;;
      @loader_path/*)
        res="$("$PY3" -c 'import os.path,sys; print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))' \
          "$dir" "${dep#@loader_path/}")"
        if [ ! -f "$PKG/$res" ]; then
          echo "错误: ${rel} 的依赖 $dep 解析到包外或不存在" >&2
          bad=1
        fi
        ;;
      *)
        echo "错误: ${rel} 存在未改写的依赖引用 $dep" >&2
        bad=1 ;;
    esac
  done < <(otool_deps "$f")
  minos="$(otool -l "$f" | awk \
    '/cmd LC_BUILD_VERSION/{b=1;next} b&&/minos/{print $2; b=0} \
     /cmd LC_VERSION_MIN_MACOSX/{v=1;next} v&&/ version /{print $2; v=0}')"
  if [ -n "$minos" ] && awk "BEGIN{exit !($minos > $MACOS_MIN)}"; then
    echo "错误: ${rel} 部署基线 $minos 高于目标 $MACOS_MIN" >&2
    bad=1
  fi
  [ "$bad" -eq 0 ] || return 1
}

log "检查 Mach-O 依赖与部署基线 (系统库外必须全部来自包内)"
VERIFY_RC=0
find "$PKG" -type f | while read -r f; do
  if is_macho "$f"; then
    verify_macho "$f" || exit 1
  fi
done || VERIFY_RC=$?
[ "$VERIFY_RC" -eq 0 ] || { echo "错误: Mach-O 便携性验证失败" >&2; exit 1; }

# 4) bin/openresty 由绝对路径 symlink 替换为便携 wrapper (同 Linux 版)
rm -f "$PKG/bin/"*.orig
rm -f "$PKG/bin/openresty"
cat > "$PKG/bin/openresty" <<'EOF'
#!/bin/sh
# 便携 wrapper: 按脚本自身位置定位包根, 以包内 nginx/ 为 prefix 启动,
# 保证任意解压位置下 conf/logs/temp 路径均正确
or_root=$(cd "$(dirname "$0")/.." && pwd)
exec "$or_root/nginx/sbin/nginx" -p "$or_root/nginx/" "$@"
EOF
chmod 755 "$PKG/bin/openresty"

# 5) 默认 nginx.conf 注入 lua 模块搜索路径 ($prefix 相对形式, 同 Linux 版)。
#    不用 sed -i (BSD/GNU 语法不同, BSD 也不解释 a\ 文本中的 \n), 用 awk 重写
INJ='lua_package_path "$prefix/../lualib/?.lua;$prefix/../site/lualib/?.lua;;";\n    lua_package_cpath "$prefix/../luajit/lib/?.so;;";'
for conf in nginx.conf nginx.conf.default; do
  awk -v inj="$INJ" '/^http \{/ && !done { print; printf "    %s\n", inj; done=1; next } { print }' \
    "$PKG/nginx/conf/$conf" > "$PKG/nginx/conf/$conf.new" \
    && mv "$PKG/nginx/conf/$conf.new" "$PKG/nginx/conf/$conf"
done
grep -q 'lua_package_path' "$PKG/nginx/conf/nginx.conf" || {
  echo "错误: 默认 conf 注入 lua_package_path 失败" >&2; exit 1; }

# bin/ 下脚本不应引用构建期绝对前缀
if grep -rl "$PREFIX" "$PKG/bin/" >/dev/null 2>&1; then
  echo "错误: 以下脚本仍引用构建期前缀 $PREFIX:" >&2
  grep -rl "$PREFIX" "$PKG/bin/" >&2
  exit 1
fi

# 不做 strip: macOS strip 与签名顺序耦合, 收益小, 风险不值
cat > "$PKG/README.txt" <<EOF
OpenResty $VERSION 便携版 (macOS $ARCH, macOS >= $MACOS_MIN)

解压即用, 目标系统只需 macOS >= $MACOS_MIN, 无需安装任何依赖库:
  - OpenSSL $OS_VER / PCRE2 $PCRE_VER / zlib $ZLIB_VER / LuaJIT 以动态链接
    方式随包分发 (lib/ 与 luajit/lib/), 依赖引用改写为 @loader_path 相对
    路径 (按可执行文件自身位置定位, 不依赖系统安装)
  - 内置 ngx_http_proxy_connect_module (HTTP CONNECT 正向代理)
  - 默认 conf 监听 80 端口, 非 root 无法绑定: 用 sudo 启动或改 listen 端口

基本用法 (推荐, 自动定位包内 nginx/ 为 prefix):
  ./bin/openresty                     # 启动 (默认 conf 监听 80)
  ./bin/openresty -s reload|quit|stop # 信号控制
  ./bin/resty -e 'print("hello")'     # LuaJIT/resty CLI

直接调 nginx 二进制需显式指定 prefix:
  ./nginx/sbin/nginx -p \$PWD/nginx/

若浏览器/访达解压后运行被 Gatekeeper 拦截 (扩展属性隔离), 执行:
  xattr -dr com.apple.quarantine <包目录>

目录结构:
  bin/     openresty 启动 wrapper, resty CLI, opm 包管理器
  lib/     OpenSSL/PCRE2/zlib 动态库 (dylib)
  nginx/   nginx 核心 (sbin/nginx, conf/, html/, logs/)
  luajit/  LuaJIT 解释器与动态库
  lualib/  lua-resty-* 库
  site/    opm 安装目录 (lualib/pod/manifest)
EOF

# ---------- L0: 构建自检 ----------
log "L0 构建自检 (nginx -V / -t)"
"$PKG/bin/openresty" -V 2>&1
"$PKG/bin/openresty" -t

# ---------- L1: 冒烟测试 ----------
# 共用 smoke-test.sh (macOS 下自动回退非特权端口跑默认 conf 场景)
# 提高文件描述符上限, 避免 worker_connections 触发 rlimit 告警
ulimit -n 2048 2>/dev/null || true
log "L1 冒烟测试 (默认conf/静态/Lua/TLS/CONNECT/resty)"
bash "$SCRIPT_DIR/smoke-test.sh" "$PKG"

# 冒烟会在包内留下运行时产物, 打包前清掉
rm -f "$PKG/nginx/logs/"*.log 2>/dev/null || true
rm -rf "$PKG/nginx/"*_temp 2>/dev/null || true

# ---------- L2: 基准测试 ----------
log "L2 基准测试 (ab)"
bash "$SCRIPT_DIR/benchmark.sh" "$PKG"

# ---------- 压缩包 ----------
log "生成压缩包"
# 防御断言: 包内不应残留运行时产物
if ls -d "$PKG/nginx/"*_temp >/dev/null 2>&1; then
  echo "错误: 包内仍存在 *_temp 临时目录" >&2
  ls -d "$PKG/nginx/"*_temp >&2
  exit 1
fi
if ls "$PKG/nginx/logs/"*.log >/dev/null 2>&1; then
  echo "错误: 包内仍存在运行日志" >&2
  exit 1
fi
# COPYFILE_DISABLE: 禁止 bsdtar 往包里塞 ._* AppleDouble 扩展属性文件
COPYFILE_DISABLE=1 tar -C "$STAGE" -cJf "$DIST.tar.xz" "$INNER"
sha256_file "$DIST.tar.xz" > "$DIST.tar.xz.sha256"

# ---------- 解压场景验证 ----------
# 解包产物到任意临时目录再跑全套冒烟 + Mach-O 检查: @loader_path 应让
# nginx/luajit 找到包内动态库, resty/wrapper 应按新位置定位 nginx
log "解压场景验证 (@loader_path + 重跑冒烟)"
VERIFY_DIR="/tmp/.or-verify-unpack.$$"
rm -rf "$VERIFY_DIR"; mkdir -p "$VERIFY_DIR"
COPYFILE_DISABLE=1 tar -xJf "$DIST.tar.xz" -C "$VERIFY_DIR"
PKG="$VERIFY_DIR/$INNER"
VERIFY_RC=0
find "$PKG" -type f | while read -r f; do
  if is_macho "$f"; then
    verify_macho "$f" || exit 1
  fi
done || VERIFY_RC=$?
if [ "$VERIFY_RC" -ne 0 ]; then
  echo "错误: 解压场景 Mach-O 验证失败" >&2
  rm -rf "$VERIFY_DIR" "$STAGE"
  exit 1
fi
bash "$SCRIPT_DIR/smoke-test.sh" "$PKG"
rm -rf "$VERIFY_DIR" "$STAGE" "$IDX"

# 输出移到工程根目录
mv "$DIST.tar.xz" "$DIST.tar.xz.sha256" "$SCRIPT_DIR/"
log "完成: $SCRIPT_DIR/$DIST.tar.xz"
