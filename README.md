# Surface Laptop Studio 2: fix "my laptop won't wake up from sleep"

If your Surface Laptop Studio 2 (or the original Surface Laptop Studio) runs
Linux and sometimes **never wakes up after you close the lid**, this fixes it.
One command, one restart, and it can be undone with one command.

I want to also state that I'm not the original person who figured this out.
The real credit goes to [David Obando](https://github.com/DavidObando) for
coming up with the first workaround this repository was built on, and to
[petm5](https://github.com/petm5) for finding the kernel parameter that turned
out to be the real fix. There's more info at the bottom of the page.

This guide assumes you have never done anything like this before. Every step
tells you exactly what to type and what you should see.

> **Work in progress.** This is one owner's fix, found by debugging one
> laptop, and it is being watched over the coming weeks. It may be updated as
> more is learned or as other people report back. Check this page again if
> something here stops matching what you see, and please
> [open an issue](https://github.com/EroJasper/sls2-suspend-fix/issues) if it
> does or does not work for you. Both kinds of report help.

---

## 1. Is this your problem?

- **The laptop.** You have a Surface Laptop Studio or Surface Laptop Studio 2.
- **The symptom.** You close the lid, come back later, and nothing wakes it.
  Not opening the lid, not the keyboard, not the power button. You have to hold
  the power button until it turns off, then start it again. A common pattern:
  the *first* sleep after a restart is fine, and it is a *later* one that
  never wakes. Short sleeps of a few seconds usually work, which is what makes
  this so confusing.
- **Any Linux.** The main fix is a kernel setting and works on any kernel. The
  optional second part needs the "linux-surface" kernel most Surface owners
  install for the touchscreen and pen. The installer checks for it and skips
  that part if it is not there.

If that sounds like your laptop, keep going.

---

## 2. Open a terminal

A terminal is the window where you type commands. How to open one depends on
your desktop:

- **Most desktops (GNOME, KDE, and others):** press the **Super** key (the one
  with the Windows logo), type `terminal`, and press Enter.
- **Omarchy / Hyprland:** press **Super + Enter**.
- **Ubuntu:** press **Ctrl + Alt + T**.

You will see a blinking cursor waiting for you to type. Everything below is
typed there, one line at a time, followed by Enter.

A tip: you can copy each command from this page and paste it into the terminal
with **Ctrl + Shift + V** (plain Ctrl+V often does not work in terminals).

---

## 3. Install the fix

Copy this whole line, paste it into the terminal, and press Enter:

```
curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh | sudo bash
```

What this does, in plain words: `curl` downloads the installer from this page,
and `sudo bash` runs it with administrator rights, which is needed to change
system files.

**You will be asked for your password.** This is your normal login password.
Nothing appears while you type it, not even dots. That is normal. Type it and
press Enter.

You should see output like this (the exact lines depend on how your system
boots):

```
Hardware: Microsoft Corporation / Surface Laptop Studio 2
  [ok] supported model

Part 1: kernel parameter
Boot configuration: limine
  backup: /etc/default/limine.bak-20260916-181500
  [ok] added pci=hpiosize=0 to /etc/default/limine
  running limine-update (this rebuilds the boot images, takes a minute)...
  [ok] boot entries regenerated

  >>> REBOOT to activate the kernel parameter. <<<

Part 2: ithc sleep hook (optional extra)
  [ok] ithc bound to 2 PCI function(s): 0000:00:10.7 0000:00:10.6
  [ok] sleep hook directory: /usr/lib/systemd/system-sleep
  [ok] installed /usr/lib/systemd/system-sleep/50-ithc-unbind
```

Every line starting with `[ok]` means that part worked. A line starting with
`error:` means it stopped; see "Something went wrong" below.

**Now restart the laptop.** The main part of the fix is a setting the kernel
reads when it starts, so it does nothing until you restart. Save your work and
restart the normal way (the power menu, or type `systemctl reboot`).

---

## 4. Check that it works

**First, the quick check.** After the restart, open a terminal and paste:

```
curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh | bash -s -- status
```

(No `sudo` needed for this one.) You want to see these three lines:

```
  [ok] pci=hpiosize=0 is active on this boot
  [ok] ACPI wake registers are not inside a PCI bridge window
  [ok] no wake-up GPE storm this boot
```

If the first line says "configured ... but NOT active yet: reboot", you have
not restarted yet.

**Then the real test,** the exact sequence that used to hang:

1. Save your work. Close the lid, wait about 30 seconds, open it. It wakes.
   Log back in.
2. Within a minute, close the lid again. Wait a minute. Open it.

Before the fix, step 2 was where it died. With the fix it should wake both
times. Run the `status` command again afterwards: the "no wake-up GPE storm"
line should still say `[ok]`. Before the fix, every wake produced thousands of
those errors.

---

## 5. What changed on your computer

**One kernel parameter** was added to your boot configuration:

```
pci=hpiosize=0
```

The installer put it in the file your bootloader reads (for Omarchy that is
`/etc/default/limine`; for most other systems `/etc/default/grub`), made a
backup of that file next to it, and regenerated the boot entries. The
"Something went wrong" section lists every file it might touch.

**One optional file** was added, if you have the linux-surface kernel:

```
/usr/lib/systemd/system-sleep/50-ithc-unbind
```

It is a short script that runs right before the laptop sleeps and right after
it wakes. You can read it here: [hooks/50-ithc-unbind](hooks/50-ithc-unbind).
The one thing you will notice from it: while the laptop is asleep, the
touchscreen, pen and touchpad are turned off. They come back the moment it
wakes. The keyboard is not affected.

Nothing else changes. No drivers, no packages, no desktop settings.

---

## 6. Undo it

To remove everything the installer did, paste this into a terminal and then
restart:

```
curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh | sudo bash -s -- uninstall
```

It removes the kernel parameter from the same file it added it to, regenerates
the boot entries, and deletes the hook file.

---

## Something went wrong

**`error: this fix is for the Surface Laptop Studio / Studio 2`**
The installer checked your hardware model and it is not a Laptop Studio. If you
have a different Surface with the same symptom and want to try anyway, add
`--force` to the end of the install command. (The Surface Pro 9 is known to
have the same bug; see "For the curious".)

**`Could not work out how your system boots`**
The installer knows Limine (Omarchy), GRUB, Fedora's `grubby`, and
systemd-boot. If yours is something else, it prints where to put the parameter
by hand. Add `pci=hpiosize=0` to your kernel command line the way your
distribution documents, then restart and run the `status` command.

**`error: the ithc driver is not loaded`** (only when running `hook`)
You are not running the linux-surface kernel. The kernel parameter part still
applies; the hook is optional.

**`sudo: command not found`** or **`curl: command not found`**
Your system is missing one of the tools the one-liner uses. Install them with
your distribution's package manager, or ask for help in the linux-surface
community with that exact error message.

**The lid test still hangs after installing and restarting.**
Run the `status` command. If the first line is not `[ok]`, the parameter did
not make it into your boot configuration; check the file for your bootloader
(below) and that you actually restarted. If all three lines are `[ok]` and it
still hung, you have a different problem from the one this fixes. Please open
an issue on this repository with the output of `status` and of
`journalctl -b -1 -k | tail -30` (the `-1` means "the previous boot").

**Files the installer may edit** (it makes a `.bak-<date>` copy first):
`/etc/default/limine`, `/etc/default/grub`, `/boot/loader/entries/*.conf`,
`/etc/kernel/cmdline`. On Fedora it uses `grubby` instead of editing files.

**I don't trust piping a download into `sudo bash`.**
Fair. Download it first, read it, then run it:

```
curl -fsSL -o install.sh https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh
less install.sh
sudo bash install.sh
```

(`less` shows the file; press `q` to quit.)

---

## Other commands

| What you want | Command |
| --- | --- |
| Check whether the fix is active and working | `curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh \| bash -s -- status` |
| Kernel parameter only, no hook | `curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh \| sudo bash -s -- param` |
| Hook only, no kernel parameter | `curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh \| sudo bash -s -- hook` |
| Test the hook without sleeping (touchpad blinks off for two seconds) | `curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh \| sudo bash -s -- test` |
| Remove everything | `curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh \| sudo bash -s -- uninstall` |

If you cloned the repository instead, replace the `curl ... |` part with
`./install.sh`, for example `sudo ./install.sh status`.

---

## For the curious: why this happens

When the laptop wakes, the kernel asks the chipset "what woke me?" by reading a
small block of I/O ports (the ACPI PM1/GPE registers, at `0x1800` on this
machine). Separately, at boot, Linux reserves a spare I/O-port window on each
hot-plug capable PCI port so that a dock plugged in later can use it. On the
Laptop Studio 2 the window it picks for the Thunderbolt root port is
`0x1000-0x1fff`, which *contains* the ACPI registers. You can see it in
`/proc/ioports`:

```
  1000-1fff : PCI Bus 0000:03        <- window given to the Thunderbolt port
    1800-1803 : ACPI PM1a_EVT_BLK    <- the wake-event registers, inside it
    1860-187f : ACPI GPE0_BLK
```

During a wake-up that port intercepts those reads and returns all-ones, so the
kernel believes *every* wake event fired at once, thousands of times over. Two
things follow. The kernel log fills with
`ACPI Error: No handler or method for GPE xx, disabling event` (millions of
lines per wake), and every wake event that has firmware code attached gets that
code queued thousands of times. That firmware code takes minutes to drain. The
*next* suspend has a step that waits for it to finish, while at the same time
shutting down the hardware that code is talking to. It never finishes. Black
screen, forever.

`pci=hpiosize=0` tells Linux not to reserve those hot-plug windows at all. The
ACPI registers are then no longer inside any PCI window, the wake-up storm is
gone (zero errors instead of thousands), and the second suspend works. The
only theoretical cost is a Thunderbolt dock device that needs legacy I/O
ports, which modern hardware does not.

**The optional hook** is the workaround this repository started with. The
touchscreen, pen and touchpad driver (`ithc`) has no sleep handling and was
reported to collide with the NVIDIA driver during suspend. Unbinding it around
sleep helped on this machine at first, but the hang came back, which led to the
investigation above. It is kept as an optional extra because it is harmless and
the author's laptop runs both. One technical note for people who write their
own hooks: the file must live in `/usr/lib/systemd/system-sleep/`; recent
systemd versions silently ignore `/etc/systemd/system-sleep/`.

### Credits

- **The ithc sleep hook** was worked out by
  [David Obando](https://github.com/DavidObando), a Surface Laptop Studio 2
  owner, in
  [linux-surface issue #1014](https://github.com/linux-surface/linux-surface/issues/1014).
  This repository started as a packaging of that idea, and it is still included.
- **The `pci=hpiosize=0` finding** comes from
  [petm5](https://github.com/petm5) in
  [linux-surface issue #1082](https://github.com/linux-surface/linux-surface/issues/1082),
  where they traced the same wake-up storm on a Surface Pro 9 to the same
  overlap and found the parameter, via
  [kernel bug 203617](https://bugzilla.kernel.org/show_bug.cgi?id=203617).
- The chain from that storm to the "stuck asleep" hang on the Laptop Studio 2
  was worked out on this repository's author's machine.

Tested on a Surface Laptop Studio 2 (Intel i7-13700H, NVIDIA RTX 2000 Ada)
with linux-surface 6.19.8, systemd 261 and Limine on Arch Linux (Omarchy).

## License

MIT, see [LICENSE](LICENSE). Use it, copy it, improve it.
