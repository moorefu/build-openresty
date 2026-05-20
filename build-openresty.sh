#!/bin/bash
set -e

# Usage: ./build-openresty.sh <version> [openssl-ver] [pcre-ver] [zlib-ver] [arch]
# Example: ./build-openresty.sh 1.29.2.4 1.1.1w 10.47 1.3.1 x86_64

VERSION="${1:?Usage: $0 <version> [openssl-ver] [pcre-ver] [zlib-ver] [arch]}"
OS_VER="${2:-1.1.1w}"
PCRE_VER="${3:-10.47}"
ZLIB_VER="${4:-1.3.1}"
ARCH="${5:-$(uname -m)}"
PREFIX=/usr/local/openresty

CACHE_DIR="${CACHE_DIR:-$(pwd)/cache}"
mkdir -p "$CACHE_DIR"

download() {
  local url="$1"
  local out="${2:-$(basename "$url")}"
  local cache_file="$CACHE_DIR/$out"
  if [ -f "$cache_file" ]; then
    echo "==> Cache hit: $cache_file"
    cp "$cache_file" "$out"
  else
    echo "==> Downloading $url"
    curl -fsSL "$url" -o "$cache_file" && cp "$cache_file" "$out"
  fi
}

echo "==> Building OpenResty ${VERSION} for ${ARCH}"

# Enable devtoolset
for dts in /opt/rh/devtoolset-*/enable; do
  [ -f "$dts" ] && source "$dts" && break
done

# Install build deps
yum install -y epel-release
yum groupinstall -y "Development Tools"
yum install -y curl pkgconfig perl-core perl-devel xz autoconf automake libtool || true

# Download OpenSSL source for OpenResty to build internally
OPENSSL_URL="https://www.openssl.org/source/openssl-${OS_VER}.tar.gz"
[ "${OS_VER%%.*}" = "3" ] && \
  OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OS_VER}/openssl-${OS_VER}.tar.gz"
download "$OPENSSL_URL"

# Download PCRE2 source
download "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VER}/pcre2-${PCRE_VER}.tar.gz"

# Download zlib source
download "https://zlib.net/zlib-${ZLIB_VER}.tar.gz"


# Download OpenResty
download "https://openresty.org/download/openresty-${VERSION}.tar.gz"

# Extract deps (OpenResty will build them itself)
tar xzf "openssl-${OS_VER}.tar.gz"
tar xzf "pcre2-${PCRE_VER}.tar.gz"
tar xzf "zlib-${ZLIB_VER}.tar.gz"

# Extract and build OpenResty
tar xzf "openresty-${VERSION}.tar.gz"
cd "openresty-${VERSION}"

./configure \
  --prefix="$PREFIX" \
  --with-openssl="../openssl-${OS_VER}" \
  --with-pcre="../pcre2-${PCRE_VER}" \
  --with-zlib="../zlib-${ZLIB_VER}" \
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
  -j$(nproc)

make -j$(nproc)
make install DESTDIR="$(pwd)/install"

# Bundle shared libs
mkdir -p "$(pwd)/install$PREFIX/lib"
for lib in libssl libcrypto; do
  find "../openssl-${OS_VER}" -name "${lib}.so*" -exec cp -a {} "$(pwd)/install$PREFIX/lib/" \; 2>/dev/null || true
done

find "$(pwd)/install" -type f -executable -exec strip --strip-all {} \; 2>/dev/null || true

DIST="openresty-${VERSION}-linux-glibc2.17-${ARCH}-openssl-${OS_VER}"
cd install
tar -cJf "../${DIST}.tar.xz" usr/local/openresty
cd ..
sha256sum "${DIST}.tar.xz" > "${DIST}.tar.xz.sha256"

mv "${DIST}.tar.xz" "${DIST}.tar.xz.sha256" ..
echo "==> Done: $(cd .. && pwd)/${DIST}.tar.xz"
