#!/bin/bash
#
# Patch broadcom-sta-dkms 6.30.223.271 for Linux kernel 6.17+
#
# Usage:
#   sudo apt install broadcom-sta-dkms
#   sudo bash patch-and-build.sh
#
# This script patches the existing broadcom-sta-dkms source in-place
# and rebuilds via DKMS. All patches are idempotent (safe to run twice).
#
set -e

SRC="/usr/src/broadcom-sta-6.30.223.271"
KVER=$(uname -r)

echo "=== Broadcom STA driver patch for kernel $KVER ==="
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root: sudo bash $0"
    exit 1
fi

if [ ! -d "$SRC" ]; then
    echo "ERROR: $SRC not found."
    echo "Install it first: sudo apt install broadcom-sta-dkms"
    exit 1
fi

# ---------------------------------------------------------------
# 1. Makefile: EXTRA_CFLAGS -> ccflags-y, EXTRA_LDFLAGS -> ldflags-y
# ---------------------------------------------------------------
echo "[1/6] Patching Makefile (EXTRA_CFLAGS -> ccflags-y)..."
if grep -q 'EXTRA_CFLAGS' "$SRC/Makefile"; then
    sed -i 's/EXTRA_CFLAGS/ccflags-y/g' "$SRC/Makefile"
    sed -i 's/EXTRA_LDFLAGS/ldflags-y/g' "$SRC/Makefile"
    echo "  Patched."
else
    echo "  Already patched, skipping."
fi

# ---------------------------------------------------------------
# 2. wl_linux.c/h: ndo_do_ioctl -> ndo_siocdevprivate
# ---------------------------------------------------------------
echo "[2/6] Patching wl_linux.c (ndo_do_ioctl -> ndo_siocdevprivate)..."
if grep -q 'ndo_do_ioctl' "$SRC/src/wl/sys/wl_linux.c"; then
    sed -i 's/\.ndo_do_ioctl = wl_ioctl/.ndo_siocdevprivate = wl_ioctl/g' "$SRC/src/wl/sys/wl_linux.c"
    sed -i 's/^wl_ioctl(struct net_device \*dev, struct ifreq \*ifr, int cmd)/wl_ioctl(struct net_device *dev, struct ifreq *ifr, void __user *data, int cmd)/' "$SRC/src/wl/sys/wl_linux.c"
    sed -i 's/extern int  wl_ioctl(struct net_device \*dev, struct ifreq \*ifr, int cmd);/extern int  wl_ioctl(struct net_device *dev, struct ifreq *ifr, void __user *data, int cmd);/' "$SRC/src/wl/sys/wl_linux.h"
    echo "  Patched."
else
    echo "  Already patched, skipping."
fi

# ---------------------------------------------------------------
# 3. Timer API: from_timer -> timer_container_of, del_timer -> timer_delete
# ---------------------------------------------------------------
echo "[3/6] Patching timer API..."
if grep -q 'from_timer' "$SRC/src/wl/sys/wl_linux.c"; then
    sed -i 's/from_timer(t, tl, timer)/timer_container_of(t, tl, timer)/' "$SRC/src/wl/sys/wl_linux.c"
    echo "  Patched from_timer -> timer_container_of."
else
    echo "  from_timer already patched, skipping."
fi

if grep -q 'del_timer(&' "$SRC/src/wl/sys/wl_linux.c"; then
    sed -i 's/del_timer(&/timer_delete(\&/g' "$SRC/src/wl/sys/wl_linux.c"
    echo "  Patched del_timer -> timer_delete."
else
    echo "  del_timer already patched, skipping."
fi

if grep -q 'del_timer_sync' "$SRC/src/include/linuxver.h"; then
    sed -i 's/#define del_timer_sync(timer) del_timer(timer)/#define del_timer_sync(timer) timer_delete(timer)/' "$SRC/src/include/linuxver.h"
    echo "  Patched del_timer_sync -> timer_delete in linuxver.h."
else
    echo "  del_timer_sync already patched, skipping."
fi

# ---------------------------------------------------------------
# 4. Add #include <linux/timer.h>
# ---------------------------------------------------------------
echo "[4/6] Ensuring linux/timer.h is included..."
if ! grep -q '#include <linux/timer.h>' "$SRC/src/wl/sys/wl_linux.c"; then
    sed -i '/#include <linux\/delay.h>/a #include <linux/timer.h>' "$SRC/src/wl/sys/wl_linux.c"
    echo "  Added."
else
    echo "  Already included, skipping."
fi

# ---------------------------------------------------------------
# 5. cfg80211 API: add radio_idx param, fix fallthrough
# ---------------------------------------------------------------
echo "[5/6] Patching cfg80211 API (radio_idx, fallthrough)..."
python3 - "$SRC/src/wl/sys/wl_cfg80211_hybrid.c" << 'PYEOF'
import sys

cfg_path = sys.argv[1]

with open(cfg_path, 'r') as f:
    content = f.read()

changes = 0

# 1. set_wiphy_params forward declaration
old = 'static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, u32 changed);'
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, int radio_idx, u32 changed);
#else
static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, u32 changed);
#endif"""
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched set_wiphy_params forward declaration")

# 2. set_wiphy_params implementation
old = 'static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, u32 changed)\n{'
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, int radio_idx, u32 changed)
#else
static s32 wl_cfg80211_set_wiphy_params(struct wiphy *wiphy, u32 changed)
#endif
{"""
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched set_wiphy_params implementation")

# 3. set_tx_power forward declaration
old = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         enum nl80211_tx_power_setting type, s32 mbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)"""
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         int radio_idx,
                         enum nl80211_tx_power_setting type, s32 mbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         enum nl80211_tx_power_setting type, s32 mbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)"""
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched set_tx_power forward declaration")

# 4. set_tx_power implementation
old = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         enum nl80211_tx_power_setting type, s32 mbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)"""
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         int radio_idx,
                         enum nl80211_tx_power_setting type, s32 mbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)
static s32
wl_cfg80211_set_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev,
                         enum nl80211_tx_power_setting type, s32 mbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)"""
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched set_tx_power implementation")

# 5. get_tx_power forward declaration
old = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)"""
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, int radio_idx, unsigned int link_id, s32 *dbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)"""
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_tx_power forward declaration")

# 6. get_tx_power implementation
old = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)"""
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 17, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, int radio_idx, unsigned int link_id, s32 *dbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0)
static s32 wl_cfg80211_get_tx_power(struct wiphy *wiphy, struct wireless_dev *wdev, u32 /*link_id*/, s32 *dbm)
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(3, 8, 0)"""
if old in content:
    content = content.replace(old, new, 1)
    changes += 1
    print("  Patched get_tx_power implementation")

# 7. fallthrough
old = '        /* falls through */'
new = '        fallthrough;'
if old in content:
    content = content.replace(old, new)
    changes += 1
    print("  Fixed fallthrough statement")

with open(cfg_path, 'w') as f:
    f.write(content)

if changes == 0:
    print("  All cfg80211 patches already applied, skipping.")
else:
    print(f"  Applied {changes} cfg80211 patches.")
PYEOF

# ---------------------------------------------------------------
# 6. DKMS rebuild
# ---------------------------------------------------------------
echo "[6/6] Rebuilding driver with DKMS..."
dkms remove broadcom-sta/6.30.223.271 --all 2>/dev/null || true
dkms install broadcom-sta/6.30.223.271 -k "$KVER" 2>&1

echo ""
echo "=== Build complete ==="

if ls /lib/modules/$KVER/updates/dkms/wl.ko* 1>/dev/null 2>&1; then
    echo "Module built successfully!"
    echo ""
    echo "To activate the driver, run:"
    echo "  sudo modprobe -r brcmfmac bcma"
    echo "  sudo modprobe wl"
    echo ""
    echo "To make it permanent:"
    echo "  sudo tee /etc/modprobe.d/broadcom-wl.conf <<EOL"
    echo "  blacklist brcmfmac"
    echo "  blacklist bcma"
    echo "  blacklist b43"
    echo "  EOL"
else
    echo "Build FAILED. Check: /var/lib/dkms/broadcom-sta/6.30.223.271/build/make.log"
    exit 1
fi
