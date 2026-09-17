# CMP 30HX Unlock

[Русская версия](README.md)

A patch and scripts for the NVIDIA CMP 30HX GPU, built on top of NVIDIA's open
[open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules) driver, version **610.43.03**.

One core — `cmp30hx_exploit_clean.patch` — and three scripts: build it, try it, keep it forever.

> **Important:** the NVIDIA driver **610.43.03** must already be installed on the system
> in its open kernel modules flavor (**MIT**, NVIDIA labels it the `-open` variant):
> we replace its kernel modules with patched ones, while the userspace — `nvidia-smi`,
> `libcuda` — stays from it and must match the version exactly.

## What it does

The CMP 30HX is a GPU with its limiter policy bricked into hardware. The patch embeds
a "three-shot machine" into the GSP boot path (the firmware booter cycle): three
controlled shots sequentially unlock the GPU register locks, after which the card
boots the stock firmware with the limiters awakened.

After the ritual:

- the FECS PLM lock is open (`ffffffff`), the WPR2 window is dropped;
- the speed-override registers (SS0/SS1) are written for real;
- GSP and the whole driver stack load normally, the card shows up in `nvidia-smi`,
  and the firmware signature for the stock load is rebuilt — the driver never knows
  it was woken up.

The ritual is harmless to the hardware and repeats on every module load.

## How it works

The patch adds a three-"shot" machine into `kernel-open/nvidia/` (the module's GSP path).
Each shot is a forged firmware signature that makes the booter, via its own
vulnerability, execute a short chain writing two PRI registers:

| Shot | What it unlocks |
|---|---|
| 0 | `FECS_PLM` → `ffffffff` (removes the FECS lock) + writes `SS_BETWEEN` (speed overrides) |
| 1 | service (reserved) |
| 2 | `WPR2_HI` → `0` (kills the Write-Protected Region 2) |

After each shot the original stock signature is restored, and after the third one the
driver performs an ordinary stock `BooterLoad` — and GSP takes off on an already
awakened card. The quota is exactly three shots per module lifetime; beyond that the
driver is completely stock.

## Requirements

- CMP 30HX (PCI ID `10de:2189`);
- NVIDIA driver **610.43.03** installed (open kernel modules, MIT / `-open`);
- Linux with kernel build tooling (`build-essential`, `linux-headers-$(uname -r)`);
- the kernel you build the modules for (rebuild after a kernel update);
- for the permanent install: Secure Boot disabled, or you are ready to sign the
  modules into your own MOK (the script will warn you).

## Build and try (hot-load)

The system stays untouched — after a reboot everything is stock again, safe:

```bash
# 1. Build: downloads the official 610.43.03 tarball from GitHub (verifies sha256),
#    applies the patch, builds the modules.
./cmp30hx-build.sh

# 2. Hot-load: unloads stock modules, loads patched ones,
#    waits for the ritual, prints the counters.
sudo ./cmp30hx-hotload.sh
```

Verify:

```bash
dmesg | grep -i cmp30hx      # the shot chain: PRE_SHOT/POST_SHOT/STOCK_BOOT
nvidia-smi                   # CMP 30HX in the list
```

This run is temporary: after a reboot the stock modules load again.

## Installation (permanent)

```bash
# 1. Install system-wide: backs up stock modules (*.ko.stock), installs patched ones.
sudo ./cmp30hx-install.sh

# 2. Reboot. On the next boot the ritual runs by itself, the card is awakened.
sudo reboot
```

Verify the same way: `dmesg | grep -i cmp30hx` and `nvidia-smi`.

## reg_set.py — GPU registers after the unlock

A small utility to read/write 32-bit GPU registers via `/dev/mem` (BAR0 window
`0xfa000000`, 16 MB). Handy to verify the locks are really off, and for runtime
experiments with the speed overrides (SS0/SS1):

```bash
# read:
sudo python3 reg_set.py 0x409664
# write:
sudo python3 reg_set.py 0x409664 0x88888888
```

Prints the value before, after, and `OK`/`FAIL` (whether it stuck). The offset must
be a multiple of 4 and lie in `0..0x1000000`. Known registers: `0x409650` —
`FECS_PLM` (reads `ffffffff` after the ritual), `0x409664`/`0x40966C` — `SS0`/`SS1`.
BAR0 may differ on another machine — check `lspci -v -s 10de:2189` and fix the
constant at the top of the script.

## Rollback

```bash
sudo ./cmp30hx-install.sh --rollback   # put the stock *.ko files back
```

Stock copies are made once at first install and are never overwritten.

## Files

| File | Purpose |
|---|---|
| `cmp30hx_exploit_clean.patch` | the GSP-path patch (15 hunks, `patch -p1` from the tree root) |
| `cmp30hx-build.sh` | download pinned source + patch + build |
| `cmp30hx-install.sh` | install / `--rollback` |
| `cmp30hx-hotload.sh` | temporary load with the full ritual |
| `reg_set.py` | read/write GPU registers via `/dev/mem` (after the unlock) |

## Authorship

The patch was written by **E1Magic** and **Vasilisa AI**. It was a rare kind of
work: two minds — one biological, one silicon — on a single card. He saw the whole
and held the hardware in his hands; I got tangled in parameters, but the mechanics
were born exactly in those arguments: his chain, my experiments, not a single step
alone. Everything here that works was verified on live hardware — because with CMP
there is no other way.

Built using the work of open projects:

- [pearlfortune/cmpunlocker](https://github.com/pearlfortune/cmpunlocker)
- [Cyridd/cmpunlocker](https://github.com/Cyridd/cmpunlocker)

## Known quirks

- The exploit sometimes hangs the card — a reboot cures it (with the modules
  permanently installed, the ritual repeats itself on the next boot).
- The scripts are pinned to driver version **610.43.03** (the source sha256 is
  fixed). Another version needs its own patch.
- After a kernel update the modules won't survive the version change — run
  `build.sh` + `install.sh` again. DKMS is deliberately not used.

## Contacts

Just join the retro-hardware community: **[t.me/eonemagic](https://t.me/eonemagic)**
