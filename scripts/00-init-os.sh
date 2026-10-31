#!/usr/bin/env bash
# ============================================================
# 00-init-os.sh  系统初始化（六台都执行一次）
# 用法:
#   sudo ./00-init-os.sh doris-node-01 192.168.1.51
#   sudo DATA_DISKS="/dev/vdb /dev/vdc" CONFIRM_FORMAT=yes \
#        ./00-init-os.sh doris-node-04 192.168.1.54
# ============================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] 请用 root 执行: sudo $0 <hostname> <ip>" >&2
  exit 1
fi

NEW_HOST="${1:?用法: $0 <hostname> <ip>}"
NEW_IP="${2:?用法: $0 <hostname> <ip>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../nodes.env"

echo "==> [1/8] 主机名 -> ${NEW_HOST}"
hostnamectl set-hostname "${NEW_HOST}"

echo "==> [2/8] 写入 /etc/hosts"
cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d)" || true
sed -i '/# >>> doris cluster/,/# <<< doris cluster/d' /etc/hosts
{
  echo "# >>> doris cluster"
  for item in "${ALL_NODES[@]}"; do
    h="${item%%:*}"; rest="${item#*:}"; ip="${rest%%:*}"
    echo "${ip} ${h}"
  done
  echo "# <<< doris cluster"
} >> /etc/hosts
grep -q "${NEW_IP}" /etc/hosts || echo "[WARN] ${NEW_IP} 不在 nodes.env 里，请检查 IP 是否写错"

echo "==> [3/8] 安装基础包 + 时间同步"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq chrony xfsprogs lsof net-tools sysstat mysql-client curl >/dev/null
systemctl enable --now chrony
timedatectl set-timezone Asia/Shanghai

echo "==> [4/8] 内核参数"
cat > /etc/sysctl.d/99-doris.conf <<'EOF'
vm.swappiness = 0
vm.max_map_count = 2000000
vm.overcommit_memory = 1
vm.zone_reclaim_mode = 0
net.core.somaxconn = 1024
net.ipv4.tcp_abort_on_overflow = 1
net.ipv4.tcp_max_syn_backlog = 1024
fs.file-max = 2000000
EOF
sysctl --system >/dev/null

echo "==> [5/8] 关闭 swap / THP / 防火墙"
swapoff -a || true
sed -i '/[[:space:]]swap[[:space:]]/s/^/#/' /etc/fstab
cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled; echo never > /sys/kernel/mm/transparent_hugepage/defrag"
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp.service
ufw disable 2>/dev/null || true
systemctl disable --now firewalld 2>/dev/null || true

echo "==> [6/8] 句柄数"
cat > /etc/security/limits.d/99-doris.conf <<'EOF'
*    soft nofile 655360
*    hard nofile 655360
*    soft nproc  655360
*    hard nproc  655360
doris soft memlock unlimited
doris hard memlock unlimited
EOF

echo "==> [7/8] 用户与目录"
id "${DORIS_USER}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${DORIS_USER}"
mkdir -p "${DORIS_HOME}"/{pkg,fe/{log,meta,data},be/{log,data}}
chown -R "${DORIS_USER}:${DORIS_USER}" "${DORIS_HOME}"

echo "==> [8/8] 数据盘（可选，只对 BE 执行）"
if [[ -n "${DATA_DISKS:-}" ]]; then
  if [[ "${CONFIRM_FORMAT:-no}" != "yes" ]]; then
    echo "[ABORT] 检测到 DATA_DISKS=${DATA_DISKS}，但未设置 CONFIRM_FORMAT=yes"
    echo "        格式化会清空数据盘，确认无误后重跑："
    echo "        sudo DATA_DISKS=\"${DATA_DISKS}\" CONFIRM_FORMAT=yes $0 ${NEW_HOST} ${NEW_IP}"
    exit 1
  fi
  idx=0
  for dev in ${DATA_DISKS}; do
    idx=$((idx+1))
    mnt="/data${idx}"
    if mountpoint -q "${mnt}"; then
      echo "    ${mnt} 已挂载，跳过 ${dev}"
      continue
    fi
    echo "    格式化 ${dev} -> ${mnt}"
    mkfs.xfs -f "${dev}"
    mkdir -p "${mnt}"
    uuid="$(blkid -s UUID -o value "${dev}")"
    grep -q "${uuid}" /etc/fstab || echo "UUID=${uuid} ${mnt} xfs defaults,noatime 0 2" >> /etc/fstab
    mount "${mnt}"
    mkdir -p "${mnt}/doris"
    chown -R "${DORIS_USER}:${DORIS_USER}" "${mnt}"
  done
  df -h /data* || true
fi

echo ""
echo "==> 完成。请确认："
echo "    hostname: $(hostname)"
echo "    ip      : $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "    时钟    : $(chronyc tracking 2>/dev/null | awk '/Leap status/{print $4}')"
echo "==> 提示：limits 修改需重新登录（su - doris）后生效"
