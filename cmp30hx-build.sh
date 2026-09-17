#!/usr/bin/env bash
# cmp30hx-build.sh — скачать open-gpu-kernel-modules 610.43.03, наложить
# патч эксплойта CMP30HX и собрать модули. Никаких прав root не требует.
#
# Артефакты: ./open-gpu-kernel-modules-610.43.03/kernel-open/*.ko
# Далее: sudo ./cmp30hx-hotload.sh  (в память)  или  sudo ./cmp30hx-install.sh  (на постоянку)
set -euo pipefail

VER=610.43.03
SHA256=9df87d753cd9c05aa0eedc462af9b35debb549a657136e863282f94c96ee2640
URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${VER}.tar.gz"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="$DIR/nvidia-open-gpu-${VER}.tar.gz"
SRC="$DIR/open-gpu-kernel-modules-${VER}"
PATCH="$DIR/cmp30hx_exploit_clean.patch"

say() { echo "==> $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

# --- окружение -------------------------------------------------------------
[ -f "$PATCH" ] || die "рядом со скриптом нет файла $(basename "$PATCH")"

for c in curl make gcc patch tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "не установлена утилита: $c"
done

KBLD="/lib/modules/$(uname -r)/build"
[ -d "$KBLD" ] || die "нет заголовков ядра ($KBLD). Поставь пакеты linux-headers-\$(uname -r) (или эквивалент для твоего дистрибутива) и kernel build tools, затем повтори."

# --- скачивание + контроль целостности ------------------------------------
if [ ! -f "$TARBALL" ]; then
    say "скачиваю исходники $VER с github.com ..."
    curl -fL --retry 3 -o "$TARBALL" "$URL" || die "скачивание не удалось"
else
    say "тарбол уже лежит: $(basename "$TARBALL") — пропускаю скачивание"
fi

if ! echo "$SHA256  $TARBALL" | sha256sum -c --quiet 2>/dev/null; then
    die "контрольная сумма тарбола не совпадает ($SHA256). Файл повреждён или подменён — удали $(basename "$TARBALL") и повтори."
fi
say "контрольная сумма верна"

# --- распаковка -------------------------------------------------------------
if [ ! -d "$SRC" ]; then
    say "распаковываю ..."
    tar xzf "$TARBALL" -C "$DIR"
else
    say "дерево уже распаковано: $(basename "$SRC")"
fi

# --- патч -------------------------------------------------------------------
if grep -q CMP30 "$SRC/src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"; then
    say "исходники уже пропатчены — пропускаю"
else
    say "проверяю применимость патча ..."
    patch -p1 -d "$SRC" --dry-run -i "$PATCH" >/dev/null \
        || die "патч не ложится на исходники $VER — проверь версию"
    patch -p1 -d "$SRC" -i "$PATCH" >/dev/null
    say "патч наложен"
fi

# --- сборка ------------------------------------------------------------------
say "собираю модули (-j$(nproc)) — это несколько минут ..."
make -C "$SRC" -j"$(nproc)" modules

# --- результат ---------------------------------------------------------------
MISS=0
for k in nvidia nvidia-uvm nvidia-modeset nvidia-drm; do
    [ -f "$SRC/kernel-open/$k.ko" ] || { echo "НЕТ $k.ko" >&2; MISS=1; }
done
[ "$MISS" -eq 0 ] || die "сборка не породила все модули"

echo
say "ГОТОВО. Патченые модули:"
ls -la "$SRC/kernel-open/"*.ko
echo
echo "Дальше по желанию:"
echo "  sudo ./cmp30hx-hotload.sh    — загрузить в память (до перезагрузки, без записи в систему)"
echo "  sudo ./cmp30hx-install.sh    — установить постоянно (с бэкапом стока и откатом)"
