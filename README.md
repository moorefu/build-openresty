# build-openresty — OpenResty 便携版构建工程

把 [OpenResty](https://openresty.org) 官方源码编译成**免依赖、解压即用**的二进制发布包：

- **Linux**：在 manylinux2014（glibc 2.17 基线）容器内构建。OpenSSL / PCRE2 / zlib /
  LuaJIT 以**动态链接**方式随包分发（`.so` 位于包内 `lib/` 与 `luajit/lib/`），
  nginx 与 luajit 解释器的 rpath 用 patchelf 改写为 `$ORIGIN` 相对路径（相对
  可执行文件自身位置，不依赖系统安装），目标机器只需 glibc >= 2.17，无需安装
  任何依赖库。OpenSSL 3.5 引入的 `libcrypt.so.2` 依赖同样随包分发在 `lib/`。
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
| Windows x86_64 | `openresty-<版本>-windows-x86_64-msys2.zip` | 官方 win 构建配置，解压即用 |

每个压缩包均附带同名 `.sha256` 校验文件。Linux 包内顶层目录为纯版本名
`openresty-<版本>/`，采用 OpenResty 标准布局：

```
openresty-<版本>/
├── bin/      openresty 启动 wrapper、resty CLI、opm 包管理器、restydoc
├── lib/      依赖动态库（libssl/libcrypto/libpcre2-8/libz/libcrypt）
├── nginx/    nginx 核心（sbin/nginx、conf/、html/、logs/）
├── luajit/   LuaJIT 解释器与动态库（lib/libluajit-5.1.so）
├── lualib/   lua-resty-* 库
└── site/     opm 安装目录（lualib/pod/manifest）
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

> 直接调 `./nginx/sbin/nginx` 需显式指定 prefix（`-p "$PWD/nginx/"`）：
> nginx 编译进二进制的默认 prefix 是构建期的 `/usr/local/openresty`，
> 裸跑不带 `-p` 无法在解压目录定位 conf。

### resty CLI（LuaJIT 一步执行）

```bash
./bin/resty -e 'io.write("hello\n")'
```

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

### Windows

```powershell
Expand-Archive openresty-1.31.1.1-windows-x86_64-msys2.zip
cd openresty-1.31.1.1-win64
.\nginx.exe             # 以当前目录为 prefix
```

> Windows 构建基于 MSYS2 工具链，性能低于原生 Linux 构建，适合开发/测试/轻量
> 场景；生产环境建议使用 Linux 构建。

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

### 为什么解压到任意目录都能直接运行

产物不依赖任何安装步骤或补丁脚本，机制如下：

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
| L1 冒烟 | `smoke-test.sh` 起六组实例做 HTTP 级断言；附加动态依赖检查（系统库只允许 glibc 家族，其余必须解析到包内） | 门禁 |
| L2 基准 | `benchmark.sh` 用 ab 跑静态/Lua 两场景吞吐，结果写入 `benchmark-<平台>-<架构>.txt` 并拼入 Release 说明 | 记录 + 残废检测 |

L1 冒烟的实例分组：

| 实例配置 | 验证点 |
| --- | --- |
| 默认 conf | 包内 conf 原样启动，resty.core 经 `$prefix` 相对路径加载（便携化核心点），正常退出 |
| 静态 | 首页内容 + stub_status 输出 |
| Lua | `content_by_lua_block` 动态输出（同时验证 LuaJIT 动态库加载） |
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

构建矩阵为 Linux x86_64 + Linux aarch64 + Windows x86_64/x86，全部通过后自动
创建 GitHub Release（tag 为 OpenResty 版本号）并上传全部产物与校验文件。
可通过 `make_latest` / `prerelease` 输入控制 Release 标记。

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
   `lualib/`、`site/lualib/`、`luajit/lib/`）。

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
├── build-openresty-win.sh                 # Windows 构建脚本（MSYS2 环境运行，官方构建流程 + 环境适配）
├── ci-fix-yum-repos.sh                    # CentOS 7 EOL 后的 yum 换源（容器内先于构建运行）
├── smoke-test.sh                          # L1 冒烟编排：起多配置实例做 HTTP 级断言
├── benchmark.sh                           # L2 基准：ab 两场景吞吐 + 结果文件
├── patches/proxy_connect_1311.patch       # proxy_connect 的 nginx 1.31+ 核心适配
├── patches/proxy_connect_module_1311.patch # proxy_connect 的模块侧适配
├── patches/resty-cli-portable.patch       # resty CLI 便携补丁（路径推导 + lua 搜索路径注入）
└── cache/                                 # 源码包缓存（git 忽略，离线构建用）
```
