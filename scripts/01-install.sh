#!/usr/bin/env bash
# ============================================================
# 01-install.sh  解包 + 铺配置（FE / BE 节点各自执行）
# 前置：把安装包放到 /opt/doris/pkg/ 下，如
#       apache-doris-4.0.8-bin-x64.tar.gz
# 用法: sudo ./01-install.sh fe
#       sudo ./01-install.sh be
# ============================================================
set -euo pipefail

ROLE="${1:?用法: $0 fe|be}"
[[ "${ROLE}" == "fe" || "${ROLE}" == "be" ]] || { echo "[ERROR] 角色只能是 fe 或 be"; exit 1; }
if [[ $EUID -ne 0 ]]; then echo "[ERROR] 请用 root 执行"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_DIR}/nodes.env"

TARGET="${DORIS_HOME}/${ROLE}"
SRC_ROOT="${PKG_DIR}/src"
mkdir -p "${PKG_DIR}"

if [[ -d "${TARGET}/bin" && "${FORCE:-no}" != "yes" ]]; then
  echo "[SKIP] ${TARGET} 已存在。要覆盖请加 FORCE=yes"
  exit 0
fi

echo "==> [1/4] 解包"
TARBALL="$(find "${PKG_DIR}" -maxdepth 1 -name 'apache-doris-*.tar.gz' | head -1)"
if [[ -z "${TARBALL}" ]]; then
  echo "[ERROR] 未找到安装包，请先放到 ${PKG_DIR}/"
  echo "        下载: https://doris.apache.org/download"
  exit 1
fi
echo "    安装包: ${TARBALL}"
rm -rf "${SRC_ROOT}"
mkdir -p "${SRC_ROOT}"
tar -xzf "${TARBALL}" -C "${SRC_ROOT}"

EXTRACT="$(find "${SRC_ROOT}" -maxdepth 3 -type d -name "${ROLE}" | head -1)"
if [[ -z "${EXTRACT}" ]]; then
  echo "[ERROR] 安装包里没找到 ${ROLE} 目录，请确认包类型（x64 / arm64）"
  exit 1
fi

echo "==> [2/4] 安装到 ${TARGET}"
rm -rf "${TARGET}"
mkdir -p "${TARGET}"
cp -a "${EXTRACT}/." "${TARGET}/"

echo "==> [3/4] 铺设配置 conf/${ROLE}.conf"
if [[ -f "${TARGET}/conf/${ROLE}.conf.orig" ]]; then
  : # 保留原始备份
else
  cp -a "${TARGET}/conf/${ROLE}.conf" "${TARGET}/conf/${ROLE}.conf.orig" 2>/dev/null || true
fi
cp -f "${REPO_DIR}/conf/${ROLE}.conf" "${TARGET}/conf/${ROLE}.conf"

echo "==> [4/4] 目录与权限"
mkdir -p "${TARGET}/log" "${TARGET}/meta" "${TARGET}/data"
chown -R "${DORIS_USER}:${DORIS_USER}" "${TARGET}"

if [[ "${ROLE}" == "be" ]]; then
  for mnt in /data1 /data2; do
    if ! mountpoint -q "${mnt}"; then
      echo "[WARN] ${mnt} 未挂载，be.conf 里配置了该路径，请先执行 00-init-os.sh 或手工挂盘"
    fi
  done
fi

echo ""
echo "==> 完成: ${TARGET}"
echo "    版本检查: ${TARGET}/bin/start_${ROLE}.sh --version 2>/dev/null || true"
echo "    校验配置差异: diff ${TARGET}/conf/${ROLE}.conf.orig ${TARGET}/conf/${ROLE}.conf | head -40"
