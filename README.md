# Surface Laptop Studio 2: fix "my laptop won't wake up from sleep"

If your Surface Laptop Studio 2 (or the original Surface Laptop Studio) runs
Linux and sometimes **never wakes up after you close the lid**, this fixes it.
No reboot needed, and it can be undone with one command.

This guide assumes you have never done anything like this before. Every step
tells you exactly what to type and what you should see.

---

## 1. Is this your problem?

All three of these should be true:

- **The laptop.** You have a Surface Laptop Studio or Surface Laptop Studio 2.
- **The symptom.** You close the lid, come back later, and nothing wakes it.
  Not opening the lid, not the keyboard, not the power button. You have to hold
  the power button until it turns off, then start it again. Short sleeps of a
  few seconds usually work fine, which is what makes this so confusing.
- **The kernel.** You are running the "linux-surface" kernel, which most people
  install on Surface devices to make the touchscreen and pen work. To check,
  open a terminal (see step 2) and type:

  ```
  uname -r
  ```

  If the answer contains the word `surface`, you have it. Example:
  `6.19.8-arch1-3-surface`. If it does not, this fix will not apply and the
  installer will tell you so. Start at
  [linux-surface](https://github.com/linux-surface/linux-surface) first.

If all three match, keep going.

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
and `sudo bash` runs it with administrator rights, which is needed to change a
system file.

**You will be asked for your password.** This is your normal login password.
Nothing appears while you type it, not even dots. That is normal. Type it and
press Enter.

You should see output like this:

```
Hardware: Microsoft Corporation / Surface Laptop Studio 2
  [ok] supported model
  [ok] ithc bound to 2 PCI function(s): 0000:00:10.7 0000:00:10.6
  [ok] sleep hook directory: /usr/lib/systemd/system-sleep
  [ok] installed /usr/lib/systemd/system-sleep/50-ithc-unbind

Next steps:
  ...
```

Every line starting with `[ok]` means that part worked. If you see a line
starting with `error:` instead, jump to the "Something went wrong" section
below.

That is the whole install. The fix is active from the next time the laptop
sleeps. You do not need to restart.

---

## 4. Check that it works

**Short test first.** Save anything you are working on, close the lid, count to
ten, open it. The screen should come back like normal. Then in the terminal
type:

```
journalctl -b -t ithc-sleep
```

This shows the fix's own log. You should see two `unbound` lines from right
before the sleep and two `rebound` lines from right after, like this:

```
Sep 15 23:12:06 omarchy ithc-sleep[6789]: unbound 0000:00:10.6 before suspend
Sep 15 23:12:06 omarchy ithc-sleep[6792]: unbound 0000:00:10.7 before suspend
Sep 15 23:12:17 omarchy ithc-sleep[6973]: rebound 0000:00:10.6 after suspend
Sep 15 23:12:17 omarchy ithc-sleep[6984]: rebound 0000:00:10.7 after suspend
```

If you see those, the fix is running.

**Then the real test.** Save your work, close the lid, and leave it closed for
at least ten minutes. Before the fix, this is exactly what caused the hang.
With the fix, it should wake normally when you open the lid.

---

## 5. What changed on your computer

Exactly one file was added:

```
/usr/lib/systemd/system-sleep/50-ithc-unbind
```

It is a short script that runs automatically right before the laptop sleeps
and right after it wakes. You can read it here:
[hooks/50-ithc-unbind](hooks/50-ithc-unbind).

Things you will notice:

- **While the laptop is asleep**, the touchscreen, pen and touchpad are turned
  off. They come back the moment it wakes. The keyboard is not affected.
- Nothing else changes. No settings, no drivers, no boot options.

---

## 6. Undo it

If you ever want to remove the fix, paste this into a terminal:

```
curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh | sudo bash -s -- uninstall
```

It deletes the one file it added. Your laptop is back to exactly how it was.

---

## Something went wrong

**`error: this fix is for the Surface Laptop Studio / Studio 2`**
The installer checked your hardware model and it is not a Laptop Studio. This
fix is specific to that machine. If you are sure you want to try anyway, add
`--force` to the end of the install command, but it may do nothing useful.

**`error: the ithc driver is not loaded`**
You are not running the linux-surface kernel (see step 1). Install that first,
then come back.

**`sudo: command not found`** or **`curl: command not found`**
Your system is missing one of the tools the one-liner uses. Install them with
your distribution's package manager, or ask for help in the linux-surface
community with that exact error message.

**The lid test still hangs after installing.**
First make sure the fix really ran: after forcing the laptop off and back on,
type `journalctl -b -1 -t ithc-sleep`. The `-1` means "the previous boot". If
there are no `unbound` lines, the hook did not run and something about your
setup is different. If there *are* `unbound` lines and it still hung, you have a
different problem from the one this fixes. Either way, please open an issue on
this repository with that output, or comment on
[linux-surface issue #1014](https://github.com/linux-surface/linux-surface/issues/1014).

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

Once installed, the same installer can do a few more things:

| What you want | Command |
| --- | --- |
| See if it is installed and view its log | `curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh \| bash -s -- status` |
| Test the fix without actually sleeping (touchpad blinks off for two seconds) | `curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh \| sudo bash -s -- test` |
| Remove the fix | `curl -fsSL https://raw.githubusercontent.com/EroJasper/sls2-suspend-fix/main/install.sh \| sudo bash -s -- uninstall` |

If you cloned the repository instead, replace the `curl ... |` part with
`./install.sh`, for example `sudo ./install.sh test`.

---

## For the curious: why this happens

The touchscreen, pen and touchpad on the Laptop Studio all go through one chip,
the Intel Touch Host Controller, driven by a Linux driver called `ithc`. That
driver has no code for handling sleep, and on this machine it collides with the
NVIDIA graphics driver while the laptop is trying to fall asleep. The kernel
gets stuck partway into suspend and never comes out.

The fix simply removes `ithc` from the picture right before sleeping
("unbind") and puts it back right after waking ("bind"). A Surface Laptop
Studio 2 owner worked this out in
[linux-surface issue #1014](https://github.com/linux-surface/linux-surface/issues/1014).
This repository just packages that idea with safety checks, a test mode, an
uninstaller, and these instructions.

One technical detail for people who maintain their own hooks: the file must
live in `/usr/lib/systemd/system-sleep/`. Recent systemd versions ignore
`/etc/systemd/system-sleep/` entirely, and a hook placed there silently never
runs. That cost a wasted test while this was being figured out.

Tested on a Surface Laptop Studio 2 (Intel i7-13700H, NVIDIA RTX 2000 Ada)
with linux-surface 6.19.8 and systemd 261 on Arch Linux (Omarchy).

## License

MIT, see [LICENSE](LICENSE). Use it, copy it, improve it.
