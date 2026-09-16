#!/usr/bin/env bash
# sls2-suspend-fix - fix "stuck asleep" suspend on the Surface Laptop Studio 2
#
# Installs a systemd sleep hook that unbinds the Intel Touch Host Controller
# (ithc) driver before suspend and rebinds it after resume. Without it, s2idle
# hangs whenever the machine sleeps for more than a few seconds.
#
# Usage (as root):
#   ./install.sh              install the hook (default)
#   ./install.sh test         run one live unbind/rebind cycle, no suspend
#   ./install.sh status       show whether the hook is installed and its log
#   ./install.sh uninstall    remove the hook
#   ./install.sh --force ...  skip the hardware model check
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh | sudo bash -s -- test
#
# Background: https://github.com/linux-surface/linux-surface/issues/1014

set -euo pipefail

HOOK_NAME=50-ithc-unbind
HOOK_DIR=/usr/lib/systemd/system-sleep
HOOK_PATH="$HOOK_DIR/$HOOK_NAME"
ITHC_DRV=/sys/bus/pci/drivers/ithc

FORCE=0
ACTION=install

usage() {
  cat <<'USAGE'
Usage: install.sh [--force] [install|test|status|uninstall]

  install     install the sleep hook (default)
  test        run one live unbind/rebind cycle without suspending
  status      show whether the hook is installed and its recent log
  uninstall   remove the hook
  --force     skip the hardware model check

Must run as root except for 'status'.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    install|test|status|uninstall) ACTION=$arg ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

bound_functions() {
  find "$ITHC_DRV" -maxdepth 1 -name '0000:*' -printf '%f ' 2>/dev/null || true
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run this as root (sudo ./install.sh $ACTION)"
}

check_hardware() {
  local product vendor n
  product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
  vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)
  say "Hardware: $vendor / $product"
  case "$product" in
    "Surface Laptop Studio"*) ok "supported model" ;;
    *)
      if [ "$FORCE" -eq 1 ]; then
        warn "not a Surface Laptop Studio, continuing because of --force"
      else
        die "this fix is for the Surface Laptop Studio / Studio 2. Use --force to install anyway."
      fi
      ;;
  esac

  [ -d "$ITHC_DRV" ] || die "the ithc driver is not loaded. This needs the linux-surface kernel: https://github.com/linux-surface/linux-surface"
  n=$(find "$ITHC_DRV" -maxdepth 1 -name '0000:*' | wc -l)
  [ "$n" -gt 0 ] || die "ithc is loaded but bound to no devices; nothing to do."
  ok "ithc bound to $n PCI function(s): $(bound_functions)"

  [ -d "$HOOK_DIR" ] || die "$HOOK_DIR does not exist; is this a systemd system?"
  ok "sleep hook directory: $HOOK_DIR"
}

write_hook() {
  # Kept in sync with hooks/50-ithc-unbind in the repository.
  cat > "$HOOK_PATH.tmp" <<'HOOK'
#!/bin/sh
# 50-ithc-unbind - systemd sleep hook for the Surface Laptop Studio (1 and 2)
#
# Unbinds the Intel Touch Host Controller (ithc) driver before suspend and
# rebinds it after resume.
#
# Why: on these machines suspend-to-idle (s2idle) hangs at
# "PM: suspend entry (s2idle)" whenever the machine is left asleep for more
# than a few seconds. It never wakes and has to be forced off. The ithc driver
# has no suspend/resume callbacks and races the NVIDIA driver during suspend.
# Taking ithc out of the picture for the duration of the sleep avoids the hang.
# Upstream discussion and the original workaround:
#   https://github.com/linux-surface/linux-surface/issues/1014
#
# Effects: touchscreen, stylus and touchpad (all behind ithc) are gone while
# asleep and return when ithc rebinds. The keyboard goes through the Surface
# Aggregator, not ithc, so it is unaffected. The rebind recreates the hidraw
# nodes, so udev starts iptsd again by itself.
#
# Devices are discovered at "pre" time and remembered in /run so the "post"
# side rebinds exactly what was unbound. Failures never block the sleep.
# Each step is logged to the journal under the tag "ithc-sleep".

STATE=/run/ithc-sleep-unbound
DRV=/sys/bus/pci/drivers/ithc

case "$1" in
  pre)
    : > "$STATE"
    for dev in "$DRV"/0000:*; do
      [ -e "$dev" ] || continue
      pci=$(basename "$dev")
      if echo "$pci" > "$DRV/unbind" 2>/dev/null; then
        echo "$pci" >> "$STATE"
        logger -t ithc-sleep "unbound $pci before $2"
      else
        logger -t ithc-sleep "failed to unbind $pci before $2"
      fi
    done
    ;;
  post)
    [ -r "$STATE" ] || exit 0
    while read -r pci; do
      [ -n "$pci" ] || continue
      if [ -e "/sys/bus/pci/devices/$pci/driver" ]; then
        continue
      fi
      if echo "$pci" > "$DRV/bind" 2>/dev/null; then
        logger -t ithc-sleep "rebound $pci after $2"
      else
        logger -t ithc-sleep "failed to rebind $pci after $2"
      fi
    done < "$STATE"
    rm -f "$STATE"
    ;;
esac

exit 0
HOOK
  chmod 0755 "$HOOK_PATH.tmp"
  mv "$HOOK_PATH.tmp" "$HOOK_PATH"
}

do_install() {
  need_root
  check_hardware
  write_hook
  ok "installed $HOOK_PATH"
  say
  say "Next steps:"
  say "  1. Optional: run 'install.sh test' for a live unbind/rebind cycle without sleeping."
  say "  2. Save your work, close the lid for ~10 seconds, reopen, then check:"
  say "       journalctl -b -t ithc-sleep"
  say "     You should see 'unbound' lines before the sleep and 'rebound' lines after."
  say "  3. Close the lid for 10+ minutes. It should wake normally."
  say
  say "Note: the touchpad, touchscreen and pen are off only while the machine is asleep."
}

do_test() {
  need_root
  [ -x "$HOOK_PATH" ] || die "hook not installed; run 'install.sh install' first"
  [ -d "$ITHC_DRV" ] || die "the ithc driver is not loaded"
  say "Running one live unbind/rebind cycle (touchpad drops for ~2 seconds)..."
  "$HOOK_PATH" pre suspend
  local after_pre after_post
  after_pre=$(find "$ITHC_DRV" -maxdepth 1 -name '0000:*' | wc -l)
  sleep 2
  "$HOOK_PATH" post suspend
  after_post=$(find "$ITHC_DRV" -maxdepth 1 -name '0000:*' | wc -l)
  say "  bound functions after pre: $after_pre, after post: $after_post"
  if [ "$after_pre" -eq 0 ] && [ "$after_post" -gt 0 ]; then
    ok "unbind and rebind both worked"
  else
    warn "unexpected result; check: journalctl -b -t ithc-sleep"
    exit 1
  fi
}

do_status() {
  if [ -x "$HOOK_PATH" ]; then
    ok "hook installed at $HOOK_PATH"
  else
    warn "hook not installed"
  fi
  if [ -d "$ITHC_DRV" ]; then
    ok "ithc bound to: $(bound_functions)"
  else
    warn "ithc driver not loaded"
  fi
  say "Recent hook activity (this boot):"
  journalctl -b -t ithc-sleep --no-pager -o short 2>/dev/null | tail -n 10 || true
}

do_uninstall() {
  need_root
  if [ -e "$HOOK_PATH" ]; then
    rm -f "$HOOK_PATH"
    ok "removed $HOOK_PATH"
  else
    say "hook was not installed"
  fi
}

case "$ACTION" in
  install)   do_install ;;
  test)      do_test ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
esac
