#!/usr/bin/env python3
# reg_set.py — установить/прочитать 32-битный регистр GPU через /dev/mem (BAR0).
#   чтение:        sudo python3 reg_set.py 0x40965c
#   установка:     sudo python3 reg_set.py 0x40965c 0x2fffff
# Печатает: значение до, после, и OK/FAIL (установилось ли).
import mmap, struct, sys

BAR0 = 0xfa000000
BAR0_SIZE = 0x1000000  # 16 MB — окно BAR0 целиком

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    off = int(sys.argv[1], 0)
    do_write = len(sys.argv) >= 3
    val = int(sys.argv[2], 0) if do_write else None
    if off % 4 or not (0 <= off < BAR0_SIZE):
        print("offset должен быть кратен 4 и лежать в 0..0x%x" % BAR0_SIZE); sys.exit(2)

    f = open('/dev/mem', 'rb+', 0)
    # mmap требует кратности страницы: выравниваем окно по 4K
    page = 0x1000
    base = off & ~(page - 1)
    m = mmap.mmap(f.fileno(), page, offset=BAR0 + base)
    def rd(a):
        return struct.unpack_from('<I', m.read(4), 0)[0] if False else \
               struct.unpack('<I', m[(a - base):(a - base) + 4])[0]
    before = rd(off)
    print("reg %s before = %s" % (hex(off), hex(before)))
    if do_write:
        m[(off - base):(off - base) + 4] = struct.pack('<I', val & 0xFFFFFFFF)  # device mem: сразу видно в чтении
        after = rd(off)
        print("reg %s after  = %s  -> %s" % (hex(off), hex(after),
              "OK" if after == (val & 0xFFFFFFFF) else "FAIL (не установилось)"))
    m.close(); f.close()

main()
