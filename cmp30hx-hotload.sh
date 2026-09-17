#!/usr/bin/env bash
# cmp30hx-hotload.sh — загрузить собранные патченые модули в память (до перезагрузки),
# дождаться полного ритуала из трёх выстрелов и вывести, что всё ОК.
# Ничего в систему не пишет. Откат — обычная перезагрузка.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KO_DIR="${KO_DIR:-$DIR/open-gpu-kernel-modules-610.43.03/kernel-open}"
WAIT_S="${WAIT_S:-180}"

say() { echo "==> $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || exec sudo bash "$0" "$@"

# --- карта ---------------------------------------------------------------
if ! lspci -d 10de:2189: | grep . >/dev/null; then
    die "в этой машине нет платы 10de:2189 (NVIDIA CMP 30HX). Патча для других карт не существует — бессмысленно."
fi
say "CMP 30HX найдена"

# --- модули ---------------------------------------------------------------
[ -d "$KO_DIR" ] || die "нет каталога с модулями: $KO_DIR (сначала ./cmp30hx-build.sh, или укажи KO_DIR=...)"
for k in nvidia nvidia-uvm; do
    [ -f "$KO_DIR/$k.ko" ] || die "нет $KO_DIR/$k.ko — собери сначала cmp30hx-build.sh"
done
grep -qa CMP30 "$KO_DIR/nvidia.ko" \
    || die "nvidia.ko не содержит маркеров CMP30 — это не патченая сборка"
say "модули на месте, nvidia.ko пропатчен"

# --- выгрузить всё, что стоит ----------------------------------------------
for m in nvidia_drm nvidia_modeset nvidia_uvm nvidia_peermem nvidia; do
    if lsmod | grep "^$m " >/dev/null; then
        rmmod "$m" 2>/dev/null && say "выгружен $m" || true
    fi
done
if lsmod | grep "^nvidia" >/dev/null; then
    echo "Модули заняты — их кто-то держит:" >&2
    lsmod | grep -e nvidia -e drm >&2
    echo "Закрой всё, что использует GPU (сессия X/Wayland, llama-server, контейнеры)," >&2
    echo "останови display manager и повтори." >&2
    exit 1
fi

# --- загрузить патченые --------------------------------------------------------
echo "CMP30HX_HOTLOAD_BEGIN" > /dev/kmsg
say "загружаю патченые модули ..."
load_mod() {
    insmod "$KO_DIR/$1.ko" 2>/dev/null && return 0
    # udev/systemd может успеть загрузить сам — тогда EEXIST, это не беда
    if lsmod | grep "^${1//-/_} " >/dev/null; then
        say "$1 уже загружен (кем-то до нас) — продолжаем"
        return 0
    fi
    die "не удалось загрузить $1"
}
load_mod nvidia
sleep 1
load_mod nvidia-uvm
[ -f "$KO_DIR/nvidia-modeset.ko" ] && load_mod nvidia-modeset || true
[ -f "$KO_DIR/nvidia-drm.ko" ] && load_mod nvidia-drm || true

# --- дождаться полного ритуала --------------------------------------------------
# секция dmesg ПОСЛЕДНЕГО маркера (не первого): иначе старые ритуалы считаются
# awk читает вход до конца: ни tac, ни dmesg не ловят SIGPIPE (sed q ловил, pipefail давал 141)
last_section() { dmesg | awk '/CMP30HX_HOTLOAD_BEGIN/{n=NR} {L[NR]=$0} END{for(i=n+1;i<=NR;i++) print L[i]}'; }
say "ждём GSP-ритуал (три выстрела + сток-загрузка), до ${WAIT_S} с ..."
OK=0
for _ in $(seq 1 "$WAIT_S"); do
    # grep -c (не -q): -q выходит досрочно, dmesg ловит SIGPIPE, pipefail превращает успех в 141
    N=$(last_section | grep -c "CMP30 STAT STOCK_BOOT" || true)
    [ "$N" -gt 0 ] && { OK=1; break; }
    sleep 1
done
[ "$OK" -eq 1 ] || die "ритуал не завершился за ${WAIT_S} с. Смотри: dmesg | grep CMP30"

SEC=$(last_section)
PRE=$(printf '%s' "$SEC" | grep -c "CMP30 STAT PRE_SHOT" || true)
POST=$(printf '%s' "$SEC" | grep -c "CMP30 STAT POST_SHOT" || true)
SBOO=$(printf '%s' "$SEC" | grep -c "CMP30 STAT STOCK_BOOT" || true)
SS=$(printf '%s' "$SEC" | grep -c "SS_BETWEEN" || true)

# --- проверка GPU ----------------------------------------------------------------
say "проверяю GPU (nvidia-smi) ..."
SMI_OK=0
for _ in $(seq 1 30); do
    nvidia-smi >/dev/null 2>&1 && { SMI_OK=1; break; }
    sleep 1
done
[ "$SMI_OK" -eq 1 ] || { echo "dmesg-след ритуала:"; printf '%s\n' "$SEC" | grep -e CMP30 -e NVRM | tail -40; die "nvidia-smi не видит GPU"; }

echo
echo "=============================================================="
echo "  ВСЁ ОК — CMP 30HX разблокирована (до перезагрузки)"
echo "  выстрелов (PRE_SHOT):  $PRE (ожидаем 3)"
echo "  POST_SHOT:             $POST"
echo "  STOCK_BOOT:            $SBOO"
echo "  SS_BETWEEN:            $SS"
echo "=============================================================="
nvidia-smi | head -12 || true   # head закрывает pipe раньше nvidia-smi — SIGPIPE под pipefail
echo
echo "Этот запуск — временный. После перезагрузки вернётся сток."
echo "На постоянку: sudo ./cmp30hx-install.sh"
