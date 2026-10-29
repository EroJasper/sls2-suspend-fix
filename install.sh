#!/usr/bin/env bash
# sls2-suspend-fix - fix "stuck asleep" suspend on the Surface Laptop Studio 2
#
# Two parts:
#   1. Kernel parameter pci=hpiosize=0 (the real fix). Linux gives the
#      Thunderbolt hot-plug root port an I/O-port window that covers the ACPI
#      power-management registers; on every wake the port intercepts those
#      reads, the kernel sees every wake event as pending, and the *next*
#      suspend hangs forever. The parameter stops Linux from reserving that
#      window. Needs a reboot to take effect.
#   2. Optional systemd sleep hook that unbinds the Intel Touch Host Controller
#      (ithc) driver around suspend. This was the original workaround and is
#      what the author's machine runs alongside part 1.
#
# Usage (as root):
#   ./install.sh              install both (default)
#   ./install.sh param        kernel parameter only
#   ./install.sh hook         sleep hook only
#   ./install.sh status       show what is installed and whether it is working
#   ./install.sh test         run one live ithc unbind/rebind cycle, no suspend
#   ./install.sh uninstall    remove both
#   ./install.sh --force ...  skip the hardware model check
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh | bash -s -- status
#
# Background:
#   https://github.com/linux-surface/linux-surface/issues/1082  (pci=hpiosize=0)
#   https://github.com/linux-surface/linux-surface/issues/1014  (ithc hook)
#   https://bugzilla.kernel.org/show_bug.cgi?id=203617

set -euo pipefail

PARAM=pci=hpiosize=0
HOOK_NAME=50-ithc-unbind
HOOK_DIR=/usr/lib/systemd/system-sleep
HOOK_PATH="$HOOK_DIR/$HOOK_NAME"
ITHC_DRV=/sys/bus/pci/drivers/ithc
STAMP=$(date +%Y%m%d-%H%M%S)

FORCE=0
ACTION=install

usage() {
  cat <<'USAGE'
Usage: install.sh [--force] [install|param|hook|test|status|uninstall]

  install     add the kernel parameter AND the sleep hook (default)
  param       add the kernel parameter pci=hpiosize=0 only (reboot needed)
  hook        install the ithc sleep hook only
  test        run one live ithc unbind/rebind cycle without suspending
  status      show what is installed and whether the fix is working
  uninstall   remove the kernel parameter and the hook
  --force     skip the hardware model check

Must run as root except for 'status'.
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    install|param|hook|test|status|uninstall) ACTION=$arg ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "run this as root (sudo ./install.sh $ACTION)"
}

bound_functions() {
  find "$ITHC_DRV" -maxdepth 1 -name '0000:*' -printf '%f ' 2>/dev/null || true
}

check_model() {
  local product vendor
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
}

# ---------------------------------------------------------------- diagnostics

param_active()     { grep -qw "$PARAM" /proc/cmdline 2>/dev/null; }

# True when the ACPI PM1a/GPE0 register blocks are listed under a PCI bridge
# window in /proc/ioports (the layout that causes the wake-up storm). The
# nesting is visible without root even though the addresses are hidden.
acpi_inside_pci_window() {
  awk '
    # $1 lets the test suite feed a saved copy of /proc/ioports.
    /: PCI Bus 0000:00$/ { depth = 0; next }
    /^  [0-9a-f]+-[0-9a-f]+ : PCI Bus / { inwin = 1; next }
    /^  [0-9a-f]+-[0-9a-f]+ : / { inwin = 0 }
    /^    [0-9a-f]+-[0-9a-f]+ : ACPI (PM1a_EVT_BLK|GPE0_BLK)/ { if (inwin) found = 1 }
    END { exit !found }
  ' "${1:-/proc/ioports}" 2>/dev/null
}

gpe_storm_count() {
  journalctl -b -k --no-pager 2>/dev/null | grep -c 'No handler or method for GPE' || true
}

# ------------------------------------------------------- kernel parameter edit

backup() { cp -p "$1" "$1.bak-$STAMP"; say "  backup: $1.bak-$STAMP"; }

# Append $PARAM inside the quotes of the first line matching $2 in file $1.
append_in_quotes() {
  local file=$1 key=$2
  if grep -q "$PARAM" "$file"; then
    ok "$file already contains $PARAM"
    return 0
  fi
  backup "$file"
  if grep -qE "^${key}=\"" "$file"; then
    sed -i -E "0,/^${key}=\"/s|^(${key}=\"[^\"]*)\"|\1 ${PARAM}\"|" "$file"
  else
    printf '%s="%s"\n' "$key" "$PARAM" >> "$file"
  fi
  grep -q "$PARAM" "$file" || die "failed to edit $file"
  ok "added $PARAM to $file"
}

remove_from_file() {
  local file=$1
  grep -q "$PARAM" "$file" || return 0
  backup "$file"
  sed -i -E "s/ ?${PARAM//./\\.}//g" "$file"
  ok "removed $PARAM from $file"
}

detect_bootloader() {
  if command -v grubby >/dev/null 2>&1 && grep -qsiE 'fedora|rhel|centos|rocky|alma' /etc/os-release; then
    echo grubby
  elif [ -e /etc/default/limine ]; then
    echo limine
  elif [ -e /etc/default/grub ]; then
    echo grub
  elif ls /boot/loader/entries/*.conf >/dev/null 2>&1; then
    echo sdboot-entries
  elif [ -e /etc/kernel/cmdline ]; then
    echo kernel-cmdline
  else
    echo unknown
  fi
}

manual_instructions() {
  cat <<EOF

  Could not work out how your system boots, so add this kernel parameter by hand:

      $PARAM

  Where it goes:
    GRUB:          /etc/default/grub, inside the quotes of GRUB_CMDLINE_LINUX_DEFAULT,
                   then run 'update-grub' (Debian/Ubuntu) or
                   'grub-mkconfig -o /boot/grub/grub.cfg' (Arch).
    Fedora:        grubby --update-kernel=ALL --args="$PARAM"
    systemd-boot:  the 'options' line of each file in /boot/loader/entries/
    Limine:        /etc/default/limine, inside the quotes of KERNEL_CMDLINE[default],
                   then run 'limine-update'.
  Then reboot. 'install.sh status' will confirm it is active.
EOF
}

do_param_add() {
  need_root
  if param_active; then
    ok "$PARAM is already active on this boot"
    return 0
  fi
  local bl; bl=$(detect_bootloader)
  say "Boot configuration: $bl"
  case "$bl" in
    grubby)
      grubby --update-kernel=ALL --args="$PARAM"
      ok "added $PARAM with grubby" ;;
    limine)
      append_in_quotes /etc/default/limine 'KERNEL_CMDLINE\[default\]\+'
      if command -v limine-update >/dev/null 2>&1; then
        say "  running limine-update (this rebuilds the boot images, takes a minute)..."
        limine-update >/dev/null
        ok "boot entries regenerated"
      else
        warn "limine-update not found; regenerate your Limine entries yourself"
      fi ;;
    grub)
      append_in_quotes /etc/default/grub 'GRUB_CMDLINE_LINUX_DEFAULT'
      if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null; ok "grub config regenerated (update-grub)"
      elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/grub/grub.cfg >/dev/null; ok "grub config regenerated (grub-mkconfig)"
      elif command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null; ok "grub config regenerated (grub2-mkconfig)"
      else
        warn "could not find update-grub/grub-mkconfig; regenerate grub.cfg yourself"
      fi ;;
    sdboot-entries)
      local f
      for f in /boot/loader/entries/*.conf; do
        grep -q "$PARAM" "$f" && { ok "$f already has it"; continue; }
        backup "$f"
        sed -i -E "s|^(options .*)$|\1 ${PARAM}|" "$f"
        ok "added $PARAM to $f"
      done ;;
    kernel-cmdline)
      if grep -q "$PARAM" /etc/kernel/cmdline; then
        ok "/etc/kernel/cmdline already has it"
      else
        backup /etc/kernel/cmdline
        sed -i -E "1s|\$| ${PARAM}|" /etc/kernel/cmdline
        ok "added $PARAM to /etc/kernel/cmdline"
        warn "now regenerate your kernel images the way your distribution does (e.g. 'mkinitcpio -P' or 'kernel-install add-all')"
      fi ;;
    *)
      manual_instructions
      return 1 ;;
  esac
  say
  say "  >>> REBOOT to activate the kernel parameter. <<<"
}

do_param_remove() {
  need_root
  local bl; bl=$(detect_bootloader)
  case "$bl" in
    grubby) grubby --update-kernel=ALL --remove-args="$PARAM"; ok "removed with grubby" ;;
    limine)
      remove_from_file /etc/default/limine
      command -v limine-update >/dev/null 2>&1 && limine-update >/dev/null && ok "boot entries regenerated" ;;
    grub)
      remove_from_file /etc/default/grub
      if command -v update-grub >/dev/null 2>&1; then update-grub >/dev/null
      elif command -v grub-mkconfig >/dev/null 2>&1; then grub-mkconfig -o /boot/grub/grub.cfg >/dev/null
      elif command -v grub2-mkconfig >/dev/null 2>&1; then grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null; fi
      ok "grub config regenerated" ;;
    sdboot-entries) local f; for f in /boot/loader/entries/*.conf; do remove_from_file "$f"; done ;;
    kernel-cmdline) remove_from_file /etc/kernel/cmdline ;;
    *) warn "could not detect the boot configuration; remove '$PARAM' from your kernel command line by hand" ;;
  esac
  param_active && say "  (the parameter stays active until the next reboot)"
  return 0
}

# ------------------------------------------------------------------ sleep hook

check_ithc() {
  [ -d "$ITHC_DRV" ] || die "the ithc driver is not loaded. The hook needs the linux-surface kernel: https://github.com/linux-surface/linux-surface"
  local n; n=$(find "$ITHC_DRV" -maxdepth 1 -name '0000:*' | wc -l)
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
# side rebinds exactly what was unbound. The "post" side also rebinds any
# ithc-capable device that has no driver, such as one whose probe timed out
# after an earlier wake, and retries a failed rebind a few times. Failures
# never block the sleep. Each step is logged to the journal under the tag
# "ithc-sleep".

STATE=/run/ithc-sleep-unbound
DRV=/sys/bus/pci/drivers/ithc

# PCI functions that ithc can drive but that have no driver right now.
unbound_ithc_devices() {
  aliases=$(modinfo -F alias ithc 2>/dev/null) || return 0
  for dev in /sys/bus/pci/devices/*; do
    [ -e "$dev/driver" ] && continue
    modalias=$(cat "$dev/modalias" 2>/dev/null) || continue
    printf '%s\n' "$aliases" | while read -r pattern; do
      case "$modalias" in
        $pattern) basename "$dev"; break ;;
      esac
    done
  done
}

# The touchpad sometimes times out (-110) while starting after a wake; another
# try a moment later works.
rebind() {
  for attempt in 1 2 3; do
    [ -e "/sys/bus/pci/devices/$1/driver" ] && return 0
    if echo "$1" > "$DRV/bind" 2>/dev/null; then
      logger -t ithc-sleep "rebound $1 after $2 (attempt $attempt)"
      return 0
    fi
    logger -t ithc-sleep "failed to rebind $1 after $2 (attempt $attempt)"
    [ "$attempt" -lt 3 ] && sleep 2
  done
  return 1
}

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
    pending=$({ cat "$STATE" 2>/dev/null; unbound_ithc_devices; } | sort -u)
    rm -f "$STATE"
    for pci in $pending; do
      rebind "$pci" "$2"
    done
    ;;
esac

exit 0
HOOK
  chmod 0755 "$HOOK_PATH.tmp"
  mv "$HOOK_PATH.tmp" "$HOOK_PATH"
}

do_hook_add() {
  need_root
  check_ithc
  write_hook
  ok "installed $HOOK_PATH"
}

do_hook_remove() {
  need_root
  if [ -e "$HOOK_PATH" ]; then
    rm -f "$HOOK_PATH"; ok "removed $HOOK_PATH"
  else
    say "  hook was not installed"
  fi
}

# --------------------------------------------------------------------- actions

do_install() {
  need_root
  check_model
  say
  say "Part 1: kernel parameter"
  do_param_add
  say
  say "Part 2: ithc sleep hook (optional extra)"
  do_hook_add
  say
  say "Next steps:"
  say "  1. Reboot."
  say "  2. Run 'install.sh status' (or the curl one-liner with 'status'). Every line should say [ok]."
  say "  3. The test that used to fail: close the lid, wait 30 s, open it and unlock,"
  say "     close it again within a minute, wait a minute, open it. It should wake both times."
}

do_status() {
  say "Kernel parameter:"
  if param_active; then
    ok "$PARAM is active on this boot"
  else
    local bl; bl=$(detect_bootloader); local f=""
    case "$bl" in limine) f=/etc/default/limine ;; grub) f=/etc/default/grub ;; kernel-cmdline) f=/etc/kernel/cmdline ;; esac
    if [ -n "$f" ] && grep -qs "$PARAM" "$f"; then
      warn "$PARAM is configured in $f but NOT active yet: reboot"
    else
      warn "$PARAM is not active (run: sudo ./install.sh param)"
    fi
  fi
  if acpi_inside_pci_window; then
    warn "ACPI wake registers are inside a PCI bridge window (the bug's precondition)"
  else
    ok "ACPI wake registers are not inside a PCI bridge window"
  fi
  local n; n=$(gpe_storm_count)
  if [ "$n" -eq 0 ]; then
    ok "no wake-up GPE storm this boot"
  else
    warn "$n 'No handler or method for GPE' errors this boot (storm still happening)"
  fi
  say "Sleep hook:"
  if [ -x "$HOOK_PATH" ]; then ok "installed at $HOOK_PATH"; else say "  [--] not installed (optional)"; fi
  if [ -d "$ITHC_DRV" ]; then ok "ithc bound to: $(bound_functions)"; else say "  [--] ithc driver not loaded (not the linux-surface kernel?)"; fi
  say "Recent sleeps (this boot):"
  journalctl -b -k --no-pager -o short 2>/dev/null | grep -E 'PM: suspend (entry|exit)' | tail -n 6 || true
  journalctl -b -t ithc-sleep --no-pager -o short 2>/dev/null | tail -n 4 || true
}

do_test() {
  need_root
  [ -x "$HOOK_PATH" ] || die "hook not installed; run 'install.sh hook' first"
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

do_uninstall() {
  need_root
  say "Removing the kernel parameter:"
  do_param_remove
  say "Removing the sleep hook:"
  do_hook_remove
  say "Done. Reboot to finish removing the kernel parameter."
}

case "$ACTION" in
  install)   do_install ;;
  param)     need_root; check_model; do_param_add ;;
  hook)      need_root; check_model; do_hook_add ;;
  test)      do_test ;;
  status)    do_status ;;
  uninstall) do_uninstall ;;
esac
