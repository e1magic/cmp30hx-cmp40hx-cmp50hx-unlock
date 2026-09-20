#!/usr/bin/env python3
# reg_set.py — установить/прочитать 32-битный регистр GPU через /dev/mem (BAR0).
#   список карт:        sudo python3 reg_set.py --list
#   чтение:             sudo python3 reg_set.py 0x40965c
#   установка:          sudo python3 reg_set.py 0x40965c 0x2fffff
#   конкретная карта:   sudo python3 reg_set.py 01:00.0 0x40965c 0x2fffff
# BAR0 берётся из sysfs (/sys/bus/pci/.../resource — текстовая таблица BAR'ов) — никакого хардкода адреса.
# Если в системе одна карта NVIDIA — BDF не нужен; если несколько — обязателен.
import mmap, os, struct, sys

PAGE = 0x1000
SYS_PCI = "/sys/bus/pci/devices"
CMP_NAMES = {
    0x2189: "CMP 30HX",
    0x1f0b: "CMP 40HX",
    0x1e09: "CMP 50HX",
}

def nvidia_gpus():
    """Найти все NVIDIA-устройства: [(bdf, devid, name, bar0_phys, bar0_size)]."""
    out = []
    if not os.path.isdir(SYS_PCI):
        return out
    for bdf in sorted(os.listdir(SYS_PCI)):
        d = os.path.join(SYS_PCI, bdf)
        try:
            vendor = int(open(os.path.join(d, "vendor")).read().strip(), 0)
            device = int(open(os.path.join(d, "device")).read().strip(), 0)
        except (OSError, ValueError):
            continue
        if vendor != 0x10DE:
            continue
        try:
            cls = int(open(os.path.join(d, "class")).read().strip(), 0)
        except (OSError, ValueError):
            cls = 0
        if cls >> 16 != 0x03:  # базовый класс 0x03 = display-контроллеры (не аудио и прочее)
            continue
        try:
            line = open(os.path.join(d, "resource")).readline().split()
            start, end = int(line[0], 0), int(line[1], 0)
        except (OSError, ValueError, IndexError):
            start, end = 0, 0
        size = (end - start + 1) if end > start else 0
        name = CMP_NAMES.get(device, "NVIDIA:%04x" % device)
        out.append((bdf, device, name, start, size))
    return out

def pick_gpu(bdf_arg, gpus):
    if not gpus:
        print("NVIDIA-карт не найдено"); sys.exit(2)
    if bdf_arg is None:
        if len(gpus) > 1:
            print("в системе несколько NVIDIA-карт — укажите BDF:")
            for bdf, devid, name, start, size in gpus:
                print("  %s  %s  BAR0=%s+%s" % (bdf, name, hex(start), hex(size)))
            sys.exit(2)
        return gpus[0]
    want = bdf_arg.lower()
    if want.count(":") == 1:
        want = "0000:" + want
    for g in gpus:
        if g[0].lower() == want:
            return g
    print("карта %s не найдена; есть:" % bdf_arg)
    for bdf, devid, name, start, size in gpus:
        print("  %s  %s" % (bdf, name))
    sys.exit(2)

def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__); sys.exit(2)
    gpus = nvidia_gpus()

    if args[0] == "--list":
        if not gpus:
            print("NVIDIA-карт не найдено"); sys.exit(1)
        for bdf, devid, name, start, size in gpus:
            cmp_tag = " [CMP]" if devid in CMP_NAMES else ""
            print("%s  %s  devid=%04x  BAR0: %s size %s%s" %
                  (bdf, name, devid, hex(start), hex(size), cmp_tag))
        return

    # первый аргумент — BDF (два/три двоеточия) или offset
    bdf_arg = None
    if ":" in args[0]:
        bdf_arg = args[0]; args = args[1:]
        if not args:
            print(__doc__); sys.exit(2)
    bdf, devid, name, bar0, bar0_size = pick_gpu(bdf_arg, gpus)

    off = int(args[0], 0)
    do_write = len(args) >= 2
    val = int(args[1], 0) if do_write else None
    if off % 4 or not (0 <= off < bar0_size):
        print("offset должен быть кратен 4 и лежать в 0..0x%x (BAR0 %s)" %
              (bar0_size, name)); sys.exit(2)
    if bar0 == 0 or bar0_size == 0:
        print("BAR0=%s size=0: sysfs скрывает адреса от непривилегированных — запускайте с sudo" % hex(bar0))
        sys.exit(2)

    print("карта: %s %s  BAR0=%s" % (bdf, name, hex(bar0)))
    f = open('/dev/mem', 'rb+', 0)
    base = off & ~(PAGE - 1)          # окно mmap, выровненное по 4K
    m = mmap.mmap(f.fileno(), PAGE, offset=bar0 + base)
    def rd(a):
        return struct.unpack('<I', m[(a - base):(a - base) + 4])[0]
    before = rd(off)
    print("reg %s before = %s" % (hex(off), hex(before)))
    if do_write:
        m[(off - base):(off - base) + 4] = struct.pack('<I', val & 0xFFFFFFFF)
        after = rd(off)
        print("reg %s after  = %s  -> %s" % (hex(off), hex(after),
              "OK" if after == (val & 0xFFFFFFFF) else "FAIL (не установилось)"))
    m.close(); f.close()

main()
