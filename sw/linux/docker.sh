#!/usr/bin/env bash
# 在 Ubuntu 24.04 的容器里跑 build.sh，与上游配方自带的 Dockerfile 同一个底：
# 配方钉的 buildroot 里有几个宿主工具（m4 等）在 GCC 15 上编不过，宿主是新发行版时走这里。
# 用法：docker.sh [<kianriscv 仓>]。build.sh 认的 TO2610_* 原样带进容器；
# 它们指到本仓与 kianriscv 仓之外的目录时，把那些目录列在 TO2610_MOUNT 里（空格分隔）
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../.." && pwd)
K=$(realpath "${1:-$R/../kianriscv}")
args=()
for v in TO2610_DTS TO2610_OVERLAY TO2610_KCONFIG TO2610_KHOOK TO2610_POST TO2610_OUT TO2610_BUILDROOT TO2610_DL; do
  [ -z "${!v:-}" ] || args+=(-e "$v=${!v}")
done
for d in "$R" "$K" ${TO2610_MOUNT:-}; do args+=(-v "$d:$d"); done
docker build --network host -q -t to2610-kvc-build "$H"
docker run --rm --network host -u "$(id -u):$(id -g)" -e HOME=/tmp "${args[@]}" \
  to2610-kvc-build bash "$H/build.sh" "$K"
