# build-openresty — OpenResty 便携版构建工程

把 [OpenResty](https://openresty.org) 官方源码编译成**免依赖、解压即用**的二进制发布包：

- **Linux**：在 manylinux2014（glibc 2.17 基线）容器内构建。OpenSSL / PCRE2 / zlib /
  LuaJIT 以**动态链接**方式随包分发（`.so` 位于包内 `lib/` 与 `luajit/lib/`），
  nginx 与 luajit 解释器的 rpath 用 patchelf 改写为 `$ORIGIN` 相对路径（相对
  可执行文件自身位置，不依赖系统安装），目标机器只需 glibc >= 2.17 与系统自带
  的 `libgcc_s`，无需安装任何依赖库（不支持 Alpine 等 musl 系统）。OpenSSL 3.5
  引入的 `libcrypt.so.2` 依赖同样随包分发在 `lib/`。
- **macOS**：在 GitHub Actions 的 macOS 15 runner（arm64 / Intel x86_64）上原生
  构建，链接基线 macOS 11.0。依赖库同样以动态链接随包分发（`dylib` 位于包内
  `lib/` 与 `luajit/lib/`），依赖引用用 `install_name_tool` 改写为
  `@loader_path` 相对路径（与 Linux 的 `$ORIGIN` 等价），解压即用。
- **Windows**：委托 OpenResty 官方 `util/build-win32.sh` 构建（MSYS2 工具链，
  与上游测试过的 Windows 配置一致），编译期 prefix 为空，nginx 以当前目录为
  prefix 运行，天然便携。

内置 [ngx_http_proxy_connect_module](https://github.com/chobits/ngx_http_proxy_connect_module)
（HTTP CONNECT 正向代理），nginx 1.31+ 的适配补丁见 `patches/`。

打包后自动做**解压场景验证**（解包产物到任意临时目录 + 清空 `LD_LIBRARY_PATH`
跑全套冒烟），持续保障便携特性。

## 构建产物

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Linux x86_64 | `openresty-<版本>-linux-glibc2.17-x86_64-openssl-<SSL版本>.tar.xz` | LuaJIT 动态库随包，rpath 定位 |
| Linux aarch64 | `openresty-<版本>-linux-glibc2.17-aarch64-openssl-<SSL版本>.tar.xz` | LuaJIT 动态库随包，rpath 定位 |
| macOS arm64 | `openresty-<版本>-macos-11.0-arm64-openssl-<SSL版本>.tar.xz` | dylib 随包，@loader_path 定位，macOS >= 11.0 |
| macOS x86_64 | `openresty-<版本>-macos-11.0-x86_64-openssl-<SSL版本>.tar.xz` | dylib 随包，@loader_path 定位，macOS >= 11.0 |
| Windows x86_64 | `openresty-<版本>-windows-x86_64-msys2.zip` | 官方 win 构建配置，解压即用 |

每个压缩包均附带同名 `.sha256` 校验文件；Release 另附汇总的 `SHA256SUMS`
与 GitHub 构建来源证明（attestation），可用 `gh attestation verify` 校验。
Linux 包内顶层目录为纯版本名
`openresty-<版本>/`，采用 OpenResty 标准布局：

```
openresty-<版本>/
├── bin/      openresty 启动 wrapper、resty CLI、opm 包管理器、restydoc
├── lib/      依赖动态库（libssl/libcrypto/libpcre2-8/libz/libcrypt）
├── nginx/    nginx 核心（sbin/nginx、conf/、html/、logs/）
├── luajit/   LuaJIT 解释器与动态库（lib/libluajit-5.1.so）
├── lualib/   lua-resty-* 库
├── site/     opm 安装目录（lualib/pod/manifest）
└── THIRD_PARTY_LICENSES.txt  第三方组件许可证（OpenSSL/PCRE2/zlib/LuaJIT 等）
```

## 使用方法

### 基本启动

```bash
tar -xJf openresty-1.31.1.1-linux-glibc2.17-x86_64-openssl-3.5.6.tar.xz
cd openresty-1.31.1.1
./bin/openresty                # 以包内 nginx/ 为 prefix 启动
curl http://127.0.0.1:8080/    # 默认 conf 监听 8080
```

`bin/openresty` 是便携 wrapper：按脚本自身位置定位包根并传 `-p`，
任意解压位置、任意调用姿势（含符号链接）下 conf/logs/temp 路径都正确。
信号控制同样走 wrapper：`./bin/openresty -s reload|quit|stop`。

> 默认 conf 监听 8080 端口（非特权），普通用户可直接启动；如需 80 端口，
> 修改 `nginx/conf/nginx.conf` 的 `listen` 并用 `sudo` 启动。Debian/Ubuntu 以 root 启动时，wrapper 会自动
> 探测 `nobody`/`nogroup` 组并把 `user nobody nogroup;` 合并进 `-g`
> （nginx 编译期默认是 `nobody:nobody`，而 Debian 系只有 `nogroup` 组），
> 含 `-g 'daemon off;'` 的容器启动姿势同样生效；自定义 conf 若已显式写 `user`，
> 需要同时给出目标系统存在的组名。
>
> 直接调 `./nginx/sbin/nginx` 需显式指定 prefix（`-p "$PWD/nginx/"`）：
> nginx 编译进二进制的默认 prefix 是构建期的 `/usr/local/openresty`，
> 裸跑不带 `-p` 无法在解压目录定位 conf。

### resty CLI（LuaJIT 一步执行）

```bash
./bin/resty -e 'io.write("hello\n")'
```

> `bin/resty`、`bin/opm` 是 Perl 脚本，运行需要系统已安装 Perl（含 `FindBin` 模块）。
> 精简镜像（如 `debian:*-slim`、`centos:7`）默认没有 Perl，先安装 `perl` 再用。

### CONNECT 正向代理（内置模块）

```nginx
server {
    listen 3128;
    resolver 8.8.8.8 valid=30s;
    proxy_connect;
    proxy_connect_allow            443 563;
    proxy_connect_connect_timeout  5s;
    proxy_connect_read_timeout     60s;
    proxy_connect_write_timeout    60s;
}
```

客户端即可经 `curl -x http://127.0.0.1:3128 https://目标` 建立隧道。

### macOS

```bash
tar -xJf openresty-1.31.1.1-macos-11.0-arm64-openssl-3.5.6.tar.xz
cd openresty-1.31.1.1
./bin/openresty                # 以包内 nginx/ 为 prefix 启动
```

- 包要求 macOS >= 11.0；arm64 包用于 Apple Silicon，x86_64 包用于 Intel 机型
  （在 Apple Silicon 上也可经 Rosetta 运行，但建议用 arm64 包）；
- 默认 conf 监听 8080 端口，非 root 可直接启动；如需 80 端口，
  改 `nginx/conf/nginx.conf` 的 `listen` 并用 `sudo` 启动；
- 若用"访达"等 GUI 方式解压后运行被 Gatekeeper 拦截，执行
  `xattr -dr com.apple.quarantine <包目录>` 清除隔离扩展属性（命令行
  `tar` 解压不会产生该问题）。

### Windows

```powershell
Expand-Archive openresty-1.31.1.1-windows-x86_64-msys2.zip
cd openresty-1.31.1.1-win64
.\start.bat             # 自动切到包根目录并启动
# 或手动（必须在包根目录内执行）：
.\nginx.exe -p .
```

> Windows 包编译期 prefix 为空，nginx 以**当前工作目录**为 prefix，因此必须在
> 解压目录内运行（从 `C:\` 等其它目录直接调 `nginx.exe` 会找不到 `conf/nginx.conf`）；
> `start.bat` 已处理这一点。`resty`/`resty.bat` 是 Perl 脚本，需要系统安装 Perl
> （如 Strawberry Perl）。包内 `README.txt` 有同样的说明。
>
> Windows 构建基于 MSYS2 工具链，性能低于原生 Linux 构建，适合开发/测试/轻量
> 场景；生产环境建议使用 Linux 构建。

## 运行环境与已知限制

- **Linux**：需要 glibc >= 2.17 与系统自带的 `libgcc_s.so.1`，其余依赖均在包内；
  不支持 Alpine 等 musl 系统（缺 glibc 装载器，表现为 `nginx: not found`）。
- **容器 / 只读根文件系统**：`nginx/logs/` 与运行期 `*_temp` 目录需要可写；
  k8s 等只读根文件系统场景请把 prefix 下这些目录挂到可写卷。
- **Debian/Ubuntu + root**：wrapper 会自动探测 `nobody`/`nogroup` 组并注入
  `user nobody nogroup;`（含 `-g 'daemon off;'` 的容器启动姿势）；自定义 conf
  若已显式写 `user`，需要自行给出目标系统存在的组名。
- **端口**：默认 conf 监听 8080（非特权），普通用户可直接启动；如需 80 端口，
  修改 `listen` 并用 `sudo` 启动。`smoke-test.sh` 在 8080 被占用时会自动换用
  高位端口。
- **resty / opm**：Perl 脚本，运行需要系统 Perl（含 `FindBin`），Windows 同理。
- **macOS**：要求 macOS >= 11.0；默认 8080 端口，普通用户可启动（改 80 需
  `sudo` 或改端口）；GUI 解压后被 Gatekeeper 拦截时按上文 `xattr` 处理。
- **Windows**：`nginx.exe` 以当前目录为 prefix，必须在包根目录运行（用
  `start.bat`）；默认 conf 监听 8080；`resty` 需要 Perl。

## 本地构建

### Linux（Docker）

```bash
docker run --rm -v "$(pwd)":/work -w /work \
  quay.io/pypa/manylinux2014_x86_64 \
  bash -c 'bash ci-fix-yum-repos.sh && bash build-openresty.sh 1.31.1.1'
```

`ci-fix-yum-repos.sh` 把 CentOS 7 EOL 后失效的 yum 源切到阿里云镜像，必须先运行。

参数依次为（均可省略，括号内为默认值）：

| 位置 | 参数 | 默认值 |
| --- | --- | --- |
| 1 | OpenResty 版本 | 必填 |
| 2 | OpenSSL 版本 | `3.5.6` |
| 3 | PCRE2 版本 | `10.47` |
| 4 | zlib 版本 | `1.3.2` |
| 5 | 目标架构 | `uname -m` |

依赖源码包会优先复用 `cache/` 目录（便于离线/本地构建），CI 冷启动时自动下载。
构建还依赖 patchelf（打包时把 rpath 改写为 `$ORIGIN` 相对路径）：manylinux 镜像
已预装；缺失时脚本自动从 [patchelf 官方 release](https://github.com/NixOS/patchelf)
下载对应架构的二进制（glibc 2.17 可运行），再不行则源码编译兜底。
`httpd-tools`（ab）为 L2 基准依赖，脚本内自动安装。

### macOS（原生）

在装有 Xcode Command Line Tools 的 macOS 11+ 上直接运行（arm64 / Intel 均可，
架构跟随当前机器）：

```bash
bash build-openresty-mac.sh 1.31.1.1
```

参数与 Linux 版一致（无第 5 位架构参数）。脚本要求 `MACOSX_DEPLOYMENT_TARGET`
（默认 11.0，可用环境变量 `MACOS_MIN` 覆盖，同时决定产物文件名中的基线标识）。
便携化手段为 `install_name_tool`：包内 dylib 的 install id 与所有 Mach-O 的
依赖引用统一改写为 `@loader_path` 相对路径、删除绝对路径 rpath，并对改写过的
二进制重新 ad-hoc 签名（arm64 必需）。CI 上对应 GitHub Actions 的
`macos-15`（arm64）与 `macos-15-intel`（x86_64，最后的 Intel 镜像）runner。

### 为什么解压到任意目录都能直接运行

产物不依赖任何安装步骤或补丁脚本，机制如下（Linux）：

- `nginx/sbin/nginx` 的 rpath 为 `$ORIGIN/../../lib:$ORIGIN/../../luajit/lib`——
  `$ORIGIN` 由 ELF 动态加载器在**运行时**解析为可执行文件自身所在目录，因此
  无论包被解压到哪个路径，`../../lib` 永远指向包内的 `lib/` 与 `luajit/lib/`；
- `luajit/bin/luajit`（resty CLI 的解释器）rpath 为 `$ORIGIN/../lib`，同理；
- 包内 `lib/` 里的 `.so` 自身 rpath 为 `$ORIGIN`，互相依赖（如 libssl 找
  libcrypto/libcrypt）也在包内解决；
- `bin/openresty` wrapper 与 `bin/resty`/`bin/opm`/`bin/restydoc` 均按脚本
  **自身位置**（`dirname $0` / `FindBin`）推导包内路径，与安装路径无关；
- 默认 `nginx.conf` 注入的 `lua_package_path` 用 `$prefix` 相对形式（ngx_lua
  原生支持运行时展开为 nginx prefix），resty.core 等 lua 库随包定位；
- patchelf 只在**构建机**上运行一次（打包期改写 rpath），不随包分发，用户侧
  无任何工具要求。每次构建打包后自动做解压场景验证（解包到任意临时目录 +
  清空 `LD_LIBRARY_PATH` 跑全套冒烟）持续保障这一特性。

macOS 版机制对应（`@loader_path` = dyld 运行时解析的"引用者自身所在目录"，
与 `$ORIGIN` 等价）：

- 包内每个 dylib 的 install id 改为 `@loader_path/<名字>`；
- nginx / luajit 解释器 / 各 dylib 对包内库的依赖引用全部改写为
  `@loader_path/<相对路径>`（构建期这些引用是 `$DEPS` 绝对路径，或 OpenResty
  给 LuaJIT 传 `PREFIX=./luajit` 产生的相对 install_name，dyld 按 CWD 解析
  必然失效）；
- 删除链接期残留的绝对路径 rpath，改写后的二进制重新 ad-hoc 签名；
- 验证同样有解压场景门禁：load commands 不得残留构建期路径，依赖只允许
  系统库（`/System`、`/usr/lib`）与可解析到包内文件的 `@loader_path` 引用，
  且部署基线（minos）不得高于发布基线。

### 编译加固（Linux）

- nginx 与随包依赖（OpenSSL/PCRE2/zlib）统一启用 `-O2 -fstack-protector-strong
  -fPIC -D_FORTIFY_SOURCE=2`，链接 `-Wl,-z,relro,-z,now`（完整 RELRO /
  BIND_NOW）；打包时断言 nginx 动态段含 `BIND_NOW`，防止参数丢失。
- rpath 用 `patchelf --force-rpath` 生成 `DT_RPATH`（而非 `DT_RUNPATH`），
  用户自行编译的 C 模块也能继承包内库搜索路径。
- 发布前对 nginx/luajit、`lib/*.so*`、`luajit/lib` 与 `lualib/*.so` 执行 strip
  （`--strip-unneeded` 保留动态符号），减小体积。
- 包内附 `THIRD_PARTY_LICENSES.txt`（OpenSSL/PCRE2/zlib/LuaJIT 及 libxcrypt 声明）。

### Windows（MSYS2）

在 GitHub Actions 的 MSYS2 MINGW64/MINGW32 环境运行 `build-openresty-win.sh`
（依赖 Strawberry Perl + mingw 工具链，详见 workflow）。脚本在官方
`util/build-win32.sh` / `util/package-win32.sh` 基础上做了少量环境适配
（MSYS2 perl 的 `$OS` 判断、`cmd /c` 路径转换、mingw32 挂载点、zlib 下载 HTTPS
化），并注入 proxy_connect 模块。打包后自动做解包冒烟（静态页 + Lua）。

### 构建过程中的自动验证（三层）

构建脚本在打包前后依次执行三层验证，前两层为**发布门禁**（失败即不发布）：

| 层级 | 内容 | 性质 |
| --- | --- | --- |
| L0 构建自检 | `nginx -V`（编译参数）+ `nginx -t`（默认 conf 语法） | 门禁 |
| L1 冒烟 | `smoke-test.sh` 起多组实例做 HTTP 级断言；附加动态依赖检查（系统库只允许 glibc 家族，其余必须解析到包内） | 门禁 |
| L2 基准 | `benchmark.sh` 用 ab 跑静态/Lua 两场景吞吐，结果写入 `benchmark-<平台>-<架构>.txt` 并拼入 Release 说明 | 记录 + 残废检测 |

L1 冒烟的实例分组：

| 实例配置 | 验证点 |
| --- | --- |
| 默认 conf | 包内 conf 原样启动，resty.core 经 `$prefix` 相对路径加载（便携化核心点），正常退出 |
| 默认 conf cpath | 复制默认 conf 追加一个 server，断言 `require "cjson"` 能从包内 `lualib/` 加载（防止 cpath 漏项回归） |
| 静态 | 首页内容 + stub_status 输出 |
| Lua | `content_by_lua_block` 动态输出 + `require "cjson"`（同时验证 LuaJIT 动态库与 lualib C 模块加载） |
| TLS | 自签证书启动，https 连接内容断言 |
| CONNECT | `--proxytunnel` 经代理隧道访问静态实例，验证 proxy_connect 模块 |
| resty CLI | `bin/resty -e` 输出断言（验证便携路径推导与 lua 路径注入） |

L2 的吞吐数字来自共享 CI runner，波动较大，不作发布门槛；只设极宽的残废检测
下限（500 req/s，正常吞吐的零头），防止构建配置错误产出性能崩坏的二进制还
照常发布。

## CI 发布（GitHub Actions）

`.github/workflows/build-openresty.yml` 支持两种触发方式：

- **手动触发**（workflow_dispatch）：在 Actions 页面运行，填写参数即可。
- **被其他工作流调用**（workflow_call）：作为可复用构建发布流程。

构建矩阵为 Linux x86_64 + Linux aarch64 + macOS arm64 + macOS x86_64（Intel）
+ Windows x86_64/x86。Linux 构建完成后还会跑目标发行版冒烟矩阵
（`centos:7`、`rockylinux:9-minimal`、`debian:11/12-slim`、
`ubuntu:20.04/24.04`，均以 root 启动 x86_64 产物），覆盖 Debian 系缺少
`nobody` 组、以及干净环境没有 `/usr/local/openresty/lualib` 这两类只在
容器里暴露的问题。全部通过后自动创建 GitHub Release（tag 为 OpenResty
版本号）并上传全部产物、汇总 `SHA256SUMS` 与构建来源证明
（`actions/attest-build-provenance`）；冒烟矩阵失败会阻断 release。
可通过 `make_latest` / `prerelease` 输入控制 Release 标记。

> 以 `workflow_call` 复用时，调用方需允许 `id-token: write` 与
> `attestations: write` 权限，否则 release 的 provenance 步骤会失败。

## 便携补丁说明

`patches/` 存放两类补丁：

**proxy_connect 的 nginx 1.31+ 适配（源码级）**：

- `proxy_connect_1311.patch`：nginx 核心适配（1.31+ 内置 CONNECT 请求行解析，
  准入由核心 `allow_connect` 控制）；
- `proxy_connect_module_1311.patch`：模块侧同步适配。

OpenResty 1.29.x 及更早版本使用模块自带补丁，无需仓库补丁。

**resty CLI 便携补丁（`resty-cli-portable.patch`，构建期应用于 configure 产物）**：

OpenResty 的 configure 会把 resty 脚本的 `my $nginx_path;` patch 成硬编码
绝对路径，且 resty 默认依赖编译进 nginx 二进制的 `LUA_DEFAULT_PATH` 绝对路径
找包内 lua 库——两者在便携包（解压到任意位置）中均失效，resty.core 加载
失败会导致 resty CLI 与 ngx_lua 完全不可用。补丁做两处还原/注入：

1. `my $nginx_path` 还原为上游自带的 FindBin 便携推导（按脚本自身位置定位
   `../nginx/sbin/nginx`）；
2. 注入按脚本位置推导的 `lua_package_path`/`lua_package_cpath`（指向包内
   `lualib/`、`site/lualib/`、`luajit/lib/`）；
3. 以 root 运行且系统没有 `nobody` 组时（Debian/Ubuntu），把
   `user nobody nogroup;` 合并进 resty 传给 nginx 的 `-g`，避免
   `getgrnam("nobody")` 失败（与 bin/openresty wrapper 同一套探测逻辑）。

此外还有两处打包期改写（非源码补丁，见 build-openresty.sh 注释）：

1. patchelf 把 nginx/luajit 的 rpath 改写为 `$ORIGIN` 相对路径；
2. `bin/openresty` 由绝对路径 symlink 替换为按脚本位置推导的 wrapper；
3. 包内默认 `nginx.conf` 注入 `$prefix` 相对形式的 `lua_package_path`——
   ngx_lua 原生支持 `$prefix` 占位符在运行时展开为 nginx prefix，使 nginx
   主进程（而非 resty CLI）也能从任意解压位置加载 resty.core。

## 目录结构

```
.
├── .github/workflows/build-openresty.yml  # CI：多平台构建 + 三层验证 + 自动发布 Release
├── build-openresty.sh                     # Linux 构建脚本（manylinux2014 容器内运行）
├── build-openresty-mac.sh                 # macOS 构建脚本（原生运行，install_name_tool 便携化）
├── build-openresty-win.sh                 # Windows 构建脚本（MSYS2 环境运行，官方构建流程 + 环境适配）
├── ci-fix-yum-repos.sh                    # CentOS 7 EOL 后的 yum 换源（容器内先于构建运行）
├── ci-smoke-distro.sh                     # 目标发行版冒烟（CI smoke-distros job 在容器内运行）
├── smoke-test.sh                          # L1 冒烟编排：起多配置实例做 HTTP 级断言
├── benchmark.sh                           # L2 基准：ab 两场景吞吐 + 结果文件
├── patches/proxy_connect_1311.patch       # proxy_connect 的 nginx 1.31+ 核心适配
├── patches/proxy_connect_module_1311.patch # proxy_connect 的模块侧适配
├── patches/resty-cli-portable.patch       # resty CLI 便携补丁（路径推导 + lua 搜索路径注入）
└── cache/                                 # 源码包缓存（git 忽略，离线构建用）
```
