# broadcom-sta patched for Linux 6.17+

Broadcom STA wireless driver (wl) version 6.30.223.271, patched to compile and run on **Linux kernel 6.17+**.

Based on `broadcom-sta-dkms 6.30.223.271-23ubuntu1.1` from Ubuntu non-free.

## Supported Hardware

Any device supported by the original broadcom-sta driver, including:

- BCM4360 (`14e4:43a0`) - tested on 2015 MacBook Pro
- BCM43602 (`14e4:43ba`)
- BCM4352 (`14e4:43b1`)
- And other chips listed in `/usr/share/broadcom-sta/broadcom-sta.ids`

## Patches Applied

| File | Change | Reason |
|------|--------|--------|
| `Makefile` | `EXTRA_CFLAGS` → `ccflags-y`, `EXTRA_LDFLAGS` → `ldflags-y` | Removed from kbuild in 6.17 |
| `wl_linux.c/h` | `ndo_do_ioctl` → `ndo_siocdevprivate` | Required since kernel 5.15 for SIOCDEVPRIVATE |
| `wl_linux.c` | `from_timer` → `timer_container_of` | `from_timer` removed in 6.17 |
| `wl_linux.c` | `del_timer` → `timer_delete` | `del_timer` removed in 6.17 |
| `wl_linux.c` | Added `#include <linux/timer.h>` | No longer transitively included |
| `linuxver.h` | `del_timer_sync` → `timer_delete` | Same timer API rename |
| `wl_cfg80211_hybrid.c` | Added `radio_idx` param to `set_wiphy_params`, `set_tx_power`, `get_tx_power` | cfg80211 multi-radio API in 6.17 |
| `wl_cfg80211_hybrid.c` | `/* falls through */` → `fallthrough;` | `-Wimplicit-fallthrough` fix |

## Install

### Option 1: DKMS (recommended)

```bash
# Copy source to DKMS location
sudo cp -r . /usr/src/broadcom-sta-6.30.223.271

# Build and install
sudo dkms install broadcom-sta/6.30.223.271

# Blacklist conflicting drivers and load wl
sudo tee /etc/modprobe.d/broadcom-wl.conf <<EOL
blacklist brcmfmac
blacklist bcma
blacklist b43
EOL

sudo modprobe -r brcmfmac bcma
sudo modprobe wl
```

### Option 2: Manual build

```bash
make KVER=$(uname -r)
sudo insmod wl.ko
```

## License

The open-source wrapper code is licensed under the **ISC License** by Broadcom Corporation.
The binary blobs (`lib/wlc_hybrid.o_*`) are proprietary. See source file headers for full license text.
