#!/usr/bin/env bash
# cmp30hx-build.sh — скачать open-gpu-kernel-modules 610.43.03, наложить
# ВЫБРАННЫЕ патчи CMP30HX и собрать модули. Права root не требует.
#
# Патчи перечислены в каталоге PATCHES ниже — новый патч = одна новая строка.
#
# Запуск:
#   ./cmp30hx-build.sh                       — интерактивный выбор патчей
#   ./cmp30hx-build.sh --patches=exploit     — неинтерактивно (id через запятую)
#   ./cmp30hx-build.sh --patches=all         — все доступные патчи
#   ./cmp30hx-build.sh --dry-run ...         — только проверить применимость, не собирать
#
# Артефакты: ./open-gpu-kernel-modules-610.43.03/kernel-open/*.ko
# Далее: sudo ./cmp30hx-hotload.sh  (в память)  или  sudo ./cmp30hx-install.sh  (на постоянку)
set -euo pipefail

VER=610.43.03
SHA256=9df87d753cd9c05aa0eedc462af9b35debb549a657136e863282f94c96ee2640
URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${VER}.tar.gz"

# --- каталог патчей ----------------------------------------------------------
# формат: id|файл|описание|файл-маркер|строка-маркер (для проверки «уже наложено»)
PATCHES=(
  "exploit|cmp30hx_exploit_clean.patch|разблокировка PLM (эксплойт GSP)|src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c|CMP30"
  "pcie2|cmp30hx_pcie2.patch|PCIe Gen2 x16 (политика + retrain при инициализации)|kernel-open/nvidia/nv.c|CMP30_PCIE_GEN2_V2"
)

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARBALL="$DIR/nvidia-open-gpu-${VER}.tar.gz"
SRC="$DIR/open-gpu-kernel-modules-${VER}"

say() { echo "==> $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }

DRYRUN=0
SEL_RAW=""
for arg in "$@"; do
    case "$arg" in
        --patches=*) SEL_RAW="${arg#--patches=}" ;;
        --dry-run)   DRYRUN=1 ;;
        -h|--help)   sed -n '2,13p' "$0"; exit 0 ;;
        *)           die "неизвестный аргумент: $arg (--help для справки)" ;;
    esac
done

patch_line_by_id() {
    local p
    for p in "${PATCHES[@]}"; do
        [ "${p%%|*}" = "$1" ] && { echo "$p"; return 0; }
    done
    return 1
}

# --- выбор патчей --------------------------------------------------------------
SELECTED=()
if [ -n "$SEL_RAW" ]; then
    SEL_RAW="${SEL_RAW//,/ }"
    if [ "$SEL_RAW" = "all" ]; then
        for p in "${PATCHES[@]}"; do SELECTED+=("${p%%|*}"); done
    else
        for id in $SEL_RAW; do
            patch_line_by_id "$id" >/dev/null || die "неизвестный id патча: $id (доступно: $(printf '%s ' "${PATCHES[@]%%|*}") all)"
            SELECTED+=("$id")
        done
    fi
elif [ -t 0 ]; then
    echo "Доступные патчи:"
    i=0
    for p in "${PATCHES[@]}"; do
        IFS='|' read -r pid pfile pdesc _ _ <<< "$p"
        i=$((i+1))
        echo "  $i) $pid — $pdesc"
    done
    echo
    printf 'Какие накладывать? (номер или id через пробел/запятую, all) > '
    read -r ans
    ans="${ans//,/ }"
    if [ "$ans" = "all" ]; then
        for p in "${PATCHES[@]}"; do SELECTED+=("${p%%|*}"); done
    else
        for a in $ans; do
            # позволяем и номера, и id
            if [[ "$a" =~ ^[0-9]+$ ]]; then
                [ "$a" -ge 1 ] && [ "$a" -le "${#PATCHES[@]}" ] || die "нет такого номера: $a"
                SELECTED+=("${PATCHES[$((a-1))]%%|*}")
            else
                patch_line_by_id "$a" >/dev/null || die "неизвестный патч: $a"
                SELECTED+=("$a")
            fi
        done
    fi
else
    die "неинтерактивный запуск требует --patches=id,id (или --patches=all); список id без аргументов не остаётся"
fi

[ "${#SELECTED[@]}" -gt 0 ] || die "не выбрано ни одного патча"
say "выбрано: ${SELECTED[*]}"

# --- окружение ---------------------------------------------------------------
for c in curl make gcc patch tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || die "не установлена утилита: $c"
done

KBLD="/lib/modules/$(uname -r)/build"
[ -d "$KBLD" ] || die "нет заголовков ядра ($KBLD). Поставь пакеты linux-headers-\$(uname -r) (или эквивалент для твоего дистрибутива) и kernel build tools, затем повтори."

# --- скачивание + контроль целостности ----------------------------------------
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

# --- распаковка -----------------------------------------------------------------
if [ ! -d "$SRC" ]; then
    say "распаковываю ..."
    tar xzf "$TARBALL" -C "$DIR"
else
    say "дерево уже распаковано: $(basename "$SRC")"
fi

# --- патчи ------------------------------------------------------------------------
for id in "${SELECTED[@]}"; do
    IFS='|' read -r pid pfile pdesc pmarkfile pmark <<< "$(patch_line_by_id "$id")"
    [ -f "$DIR/$pfile" ] || die "рядом со скриптом нет файла $pfile"
    if [ -f "$SRC/$pmarkfile" ] && grep -qa "$pmark" "$SRC/$pmarkfile"; then
        say "$pid ($pdesc): уже наложено — пропускаю"
        continue
    fi
    say "$pid: проверяю применимость ..."
    patch -p1 -d "$SRC" --dry-run -i "$DIR/$pfile" >/dev/null \
        || die "$pid: патч не ложится на исходники $VER — проверь версию"
    if [ "$DRYRUN" -eq 1 ]; then
        say "$pid: применимо (dry-run, не накладываю)"
        continue
    fi
    patch -p1 -d "$SRC" -i "$DIR/$pfile" >/dev/null
    say "$pid: наложен"
done

if [ "$DRYRUN" -eq 1 ]; then
    say "dry-run окончен: ничего не накладывал и не собирал"
    exit 0
fi

# --- сборка -----------------------------------------------------------------------
say "собираю модули (-j$(nproc)) — это несколько минут ..."
make -C "$SRC" -j"$(nproc)" modules

# --- результат ---------------------------------------------------------------------
MISS=0
for k in nvidia nvidia-uvm nvidia-modeset nvidia-drm; do
    [ -f "$SRC/kernel-open/$k.ko" ] || { echo "НЕТ $k.ko" >&2; MISS=1; }
done
[ "$MISS" -eq 0 ] || die "сборка не породила все модули"

echo
say "ГОТОВО. Патченые модули (${SELECTED[*]}):"
ls -la "$SRC/kernel-open/"*.ko
echo
echo "Дальше по желанию:"
echo "  sudo ./cmp30hx-hotload.sh    — загрузить в память (до перезагрузки, без записи в систему)"
echo "  sudo ./cmp30hx-install.sh    — установить постоянно (с бэкапом стока и откатом)"
