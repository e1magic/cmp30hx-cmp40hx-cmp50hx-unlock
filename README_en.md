# CMP 30HX / 40HX / 50HX Unlock

[Русская версия](README.md)

Patches and scripts for NVIDIA CMP **30HX / 40HX / 50HX** GPUs, built on top of
NVIDIA's open [open-gpu-kernel-modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
driver, version **610.43.03**.

Two patches — the PLM unlock (`cmp_exploit_clean.patch`) and PCIe Gen2
(`cmp_pcie2.patch`) — and three scripts: build (with patch selection), try, keep forever.

> **Important:** the NVIDIA driver **610.43.03** must already be installed on the system
> in its open kernel modules flavor (**MIT**, NVIDIA labels it the `-open` variant):
> we replace its kernel modules with patched ones, while the userspace — `nvidia-smi`,
> `libcuda` — stays from it and must match the version exactly.

## What it does

CMP cards carry a limiter policy bricked into hardware. The patch embeds a
"three-shot machine" into the GSP boot path (the firmware booter cycle): three
controlled shots sequentially unlock the GPU register locks, after which the card
boots the stock firmware with the limiters awakened. The patch works on all three
cards (PCI IDs `10de:2189`, `10de:1f0b`, `10de:1e09`).

After the ritual:

- the FECS PLM lock is open (`ffffffff`), the WPR2 window is dropped;
- the speed-override registers (SS0/SS1) are written for real;
- GSP and the whole driver stack load normally, the card shows up in `nvidia-smi`,
  and the firmware signature for the stock load is rebuilt — the driver never knows
  it was woken up.

The ritual is harmless to the hardware and repeats on every module load.

## What you get

Live measurements on a **CMP 50HX** (GEMM 4096x4096):

| Metric | Before | After unlock |
|---|---|---|
| FP32 kernel | 0.853 TFLOPS | **27.117 TFLOPS** |
| FP16 kernel | 54.6 TFLOPS | 54.6 TFLOPS |
| FP32 cuBLAS | 0.422 TFLOPS | **12.495 TFLOPS** |
| FP16 cuBLAS | 3.118 TFLOPS | **88.376 TFLOPS** |
| FP64 | ~0.85 / 0.42 TFLOPS | unchanged (stock) |

On CMP 40HX and 50HX the exploit gives a multiple performance gain. On CMP 30HX
it opens room for experiments. PCIe Gen2 (see below) works on all three cards.

Several CMP cards can run in the same machine mixed together: the ritual is
applied to each card separately and does not interfere with the others.

## How it works

The patch adds a three-"shot" machine into the module's GSP path. Each shot is a
forged firmware signature that makes the booter, via its own vulnerability,
execute a short chain writing GPU PRI registers:

| Shot | What it unlocks |
|---|---|
| 0 | `FECS_PLM` → `ffffffff` (removes the FECS lock) + service chain |
| 1 | kills `WPR2` (Write-Protected Region 2), PLM chain |
| 2 | final chain; between shots the speed overrides `SS0/SS1` are written |

After each shot the original stock signature is restored, and after the third one the
driver performs an ordinary stock `BooterLoad` — and GSP takes off on an already
awakened card. The quota is exactly three shots per module lifetime; beyond that the
driver is completely stock.

## Patches and selection

| id | File | What it does |
|---|---|---|
| `exploit` | `cmp_exploit_clean.patch` | PLM/GSP unlock (see "What it does") |
| `pcie2` | `cmp_pcie2.patch` | PCIe Gen2 x16 (see "PCIe Gen2") |

The patches are independent — apply either one or both. The build asks which
patches to apply:

```bash
./cmp-build.sh                       # interactive pick (numbers/ids/all)
./cmp-build.sh --patches=all         # non-interactive: both
./cmp-build.sh --patches=exploit     # unlock only
./cmp-build.sh --dry-run --patches=all   # only check applicability
```

An already-applied patch is detected by its marker in the sources and skipped —
rerunning is safe. A third patch = one line in the `PATCHES` catalog at the top
of `cmp-build.sh` + the patch file next to the script.

## PCIe Gen2

The card sits on Gen1 (2.5 GT/s) out of the box. The `pcie2` patch works in two
places of the module load path: (1) after GSP is ready it clears the Gen2
software fuse and sets the speed policy in the GPU's PCIe block; (2) on the
first device open it runs a short series of link retrains (bridge → endpoint →
bridge) targeting 5 GT/s on both ends. The hardware picks the speed, so the
first attempt is not guaranteed — the machine fires up to three pulses.
Works on CMP 30HX/40HX/50HX.

Verify:

```bash
sudo lspci -vv -d 10de:2189 | grep LnkSta   # Speed 5GT/s, Width x16 — no "downgraded" note
sudo dmesg | grep CMP_PCIE_GEN2_V2          # RETRAIN_PASS status=1102 attempt=N
```

Live run on x16 Gen2: D2D ~301 GB/s, H2D/D2H ~6.7 GB/s (≈97% of bus bandwidth).

> **Never poke the link retrain/RL register from the OS runtime** (setpci etc.):
> on Intel chipsets it drops the link and leaves the card dead in config
> space until a cold power cycle. All retraining lives in the patch, at module load.

## Requirements

- CMP 30HX (`10de:2189`), CMP 40HX (`10de:1f0b`) or CMP 50HX (`10de:1e09`);
- NVIDIA driver **610.43.03** installed (open kernel modules, MIT / `-open`);
- Linux with kernel build tooling (`build-essential`, `linux-headers-$(uname -r)`);
- the kernel you build the modules for (rebuild after a kernel update);
- for the permanent install: Secure Boot disabled, or you are ready to sign the
  modules into your own MOK (the script will warn you).

## Build and try (hot-load)

The system stays untouched — after a reboot everything is stock again, safe:

```bash
# 1. Build: downloads the official 610.43.03 tarball from GitHub (verifies sha256),
#    asks which patches to apply (or --patches=...), builds the modules.
./cmp-build.sh

# 2. Hot-load: unloads stock modules, loads patched ones,
#    waits for the ritual, prints the counters.
sudo ./cmp-hotload.sh
```

Verify:

```bash
sudo dmesg | grep -i -E 'NVRM|nvidia-drm'   # the shot chain: PRE_SHOT/POST_SHOT/STOCK_BOOT
nvidia-smi                                  # CMP card in the list
```

This run is temporary: after a reboot the stock modules load again.

## Installation (permanent)

```bash
# 1. Install system-wide: backs up stock modules (*.ko.stock), installs patched ones.
sudo ./cmp-install.sh

# 2. Reboot. On the next boot the ritual runs by itself, the card is awakened.
sudo reboot
```

Verify the same way: `sudo dmesg | grep -i -E 'NVRM|nvidia-drm'` and `nvidia-smi`.

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
BAR0 may differ on another machine — check `lspci -v -d 10de:2189` and fix the
constant at the top of the script.

## Rollback

```bash
sudo ./cmp-install.sh --rollback   # put the stock *.ko files back
```

Stock copies are made once at first install and are never overwritten.

## Files

| File | Purpose |
|---|---|
| `cmp_exploit_clean.patch` | the GSP-path patch (PLM unlock for 30HX/40HX/50HX, `patch -p1` from the tree root) |
| `cmp_pcie2.patch` | the PCIe Gen2 patch (3 cards, `patch -p1` from the tree root) |
| `cmp-build.sh` | download pinned source + patch selection + build |
| `cmp-install.sh` | install / `--rollback` |
| `cmp-hotload.sh` | temporary load with the full ritual |
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
  `cmp-build.sh` + `cmp-install.sh` again. DKMS is deliberately not used.

## Contacts

Just join the retro-hardware community: **[t.me/eonemagic](https://t.me/eonemagic)**
