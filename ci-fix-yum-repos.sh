#!/bin/bash
# CentOS 7 已于 2024-06-30 EOL，官方 yum 源已失效（mirrorlist 404 / vault 403）。
# 本脚本在 manylinux2014（CentOS 7.9）容器内、执行 build-openresty.sh 之前运行，
# 按架构处理 yum 源：
#   x86_64  base/updates/extras -> mirrors.aliyun.com/centos-vault/7.9.2009
#           （镜像自带源失效，阿里云 vault 有 x86_64）
#   aarch64 base/updates/extras 保持镜像自带源不动
#           （阿里云/清华 vault 均无 aarch64 目录 404；manylinux2014_aarch64
#            自带源可用，build-memcached 的 aarch64 CI 一直如此使用）
#   两架构  epel -> mirrors.aliyun.com/epel-archive/7（提供 perl-IPC-Cmd 等）
set -e

ARCH="$(uname -m)"

if [ "$ARCH" = "x86_64" ]; then
  # 覆盖 CentOS base/updates/extras 源（vault 目录使用 7.9.2009）
  cat > /etc/yum.repos.d/CentOS-Base.repo <<'EOF'
[base]
name=CentOS-7.9.2009 - Base (aliyun vault)
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-7.9.2009 - Updates (aliyun vault)
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-7.9.2009 - Extras (aliyun vault)
baseurl=https://mirrors.aliyun.com/centos-vault/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
EOF

  # 移除其他已失效的 CentOS repo，避免干扰
  rm -f /etc/yum.repos.d/CentOS-CR.repo \
        /etc/yum.repos.d/CentOS-Debuginfo.repo \
        /etc/yum.repos.d/CentOS-fasttrack.repo \
        /etc/yum.repos.d/CentOS-Media.repo \
        /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo \
        /etc/yum.repos.d/CentOS-Sources.repo \
        /etc/yum.repos.d/CentOS-Updates.repo \
        /etc/yum.repos.d/CentOS-Extras.repo \
        /etc/yum.repos.d/CentOS-Vault.repo \
        /etc/yum.repos.d/CentOS-x86_64-kernel.repo
else
  echo "==> aarch64: 保留镜像自带 base/updates/extras 源 (aliyun vault 无 aarch64)"
fi

# EPEL（提供 perl-Text-Template 等）：安装后把源切换到阿里云 epel-archive
yum install -y epel-release || true
if [ -f /etc/yum.repos.d/epel.repo ]; then
  sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/epel.repo
  sed -i 's|^#baseurl=|baseurl=|g' /etc/yum.repos.d/epel.repo
  sed -i 's|https://dl.fedoraproject.org/pub/epel/7|https://mirrors.aliyun.com/epel-archive/7|g' \
      /etc/yum.repos.d/epel.repo
  sed -i 's|http://dl.fedoraproject.org/pub/epel/7|https://mirrors.aliyun.com/epel-archive/7|g' \
      /etc/yum.repos.d/epel.repo
fi

# 清缓存并验证
yum clean all >/dev/null 2>&1 || true
echo "==> yum repos fixed:"
yum repolist 2>&1 | tail -5
