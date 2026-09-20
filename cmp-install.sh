#!/usr/bin/env bash
# cmp-install.sh — установить патченые модули в дерево ядра НАПОСТОЯНУ.
#   sudo ./cmp-install.sh              — установка (с бэкапом стока)
#   sudo ./cmp-install.sh --rollback   — вернуть сток на место
# Сборку инициализирует сам пользователь — скрипт только меняет .ko на собранные им.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KO_DIR="${KO_DIR:-$DIR/open-gpu-kernel-modules-610.43.03/kernel-open}"
MODS=(nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem)

say() { echo "==> $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

[ "$EUID" -eq 0 ] || exec sudo bash "$0" "$@"

finish() {
    depmod -a
    if command -v update-initramfs >/dev/null 2>&1; then
        say "перегенерю initramfs ..."
        update-initramfs -u >/dev/null
    fi
    say "теперь перезагрузись: sudo reboot"
}

# --- откат -----------------------------------------------------------------
if [ "${1:-}" = "--rollback" ]; then
    D="$(dirname "$(modinfo -n nvidia 2>/dev/null || true)")"
    [ -n "$D" ] && [ -d "$D" ] || die "не нашёл каталог модулей ядра"
    RESTORED=0
    for k in "${MODS[@]}"; do
        if [ -f "$D/$k.ko.stock" ]; then
            cp -f "$D/$k.ko.stock" "$D/$k.ko"
            say "восстановлен $D/$k.ko"
            RESTORED=1
        fi
    done
    [ "$RESTORED" -eq 1 ] || die "бэкапов ($k.ko.stock) здесь нет — откатывать нечего: $D"
    finish
    say "сток возвращён"
    exit 0
fi

# --- проверка окружения ------------------------------------------------------
[ -d "$KO_DIR" ] || die "нет каталога с модулями: $KO_DIR (сначала ./cmp-build.sh)"
for k in nvidia nvidia-uvm; do
    [ -f "$KO_DIR/$k.ko" ] || die "нет $KO_DIR/$k.ko — собери сначала cmp-build.sh"
done
grep -qa CMP "$KO_DIR/nvidia.ko" \
    || die "nvidia.ko не содержит маркеров CMP — это не патченая сборка"
say "патченые модули на месте"

D="$(dirname "$(modinfo -n nvidia 2>/dev/null || true)")"
if [ -z "$D" ] || [ ! -d "$D" ]; then
    D="/lib/modules/$(uname -r)/kernel/drivers/video"
    say "сток-модуль nvidia сейчас не загружен/не установлен, ставлю в $D"
    mkdir -p "$D"
fi
say "каталог установки: $D"

# --- safe boot подсказка -----------------------------------------------------
if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    echo
    echo "ВНИМАНИЕ: включён Secure Boot. Неподписанные модули ядро не пустит." >&2
    echo "Подпиши модули своим MOK-ключом (mokutil + sign-file из пакетов ядра)" >&2
    echo "или отключи Secure Boot в UEFI. Это действие на стороне пользователя." >&2
    echo
fi

# --- бэкап стока (один раз, поверх не пишем) -----------------------------------
for k in "${MODS[@]}"; do
    if [ -f "$D/$k.ko" ] && [ ! -f "$D/$k.ko.stock" ]; then
        cp -a "$D/$k.ko" "$D/$k.ko.stock"
        say "бэкап стока: $D/$k.ko.stock"
    elif [ -f "$D/$k.ko.stock" ]; then
        say "бэкап уже есть: $D/$k.ko.stock"
    fi
done

# --- установка -----------------------------------------------------------------
for k in "${MODS[@]}"; do
    [ -f "$KO_DIR/$k.ko" ] || { say "пропускаю $k (не собран)"; continue; }
    cp -f "$KO_DIR/$k.ko" "$D/$k.ko"
    say "установлен $D/$k.ko"
done

finish
echo
echo "Патч будет действовать после перезагрузки на каждой загрузке."
echo "Откат: sudo ./cmp-install.sh --rollback"
