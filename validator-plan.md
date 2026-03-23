## Plan: Config Validator & Post-Install Smoke Test

Add two verification layers around the installer: (1) a pre-install JSON config schema validator that catches typos/invalid values in install.json profiles before `automated.sh` substitutes them into `install.sh`, and (2) a post-install smoke test (`--verify` flag) that arch-chroots into the new system and confirms critical setup before reboot.

---

### Phase 1: Config Schema Validator

**New file:** `archlinux/installation/validate-config.sh`

Standalone script called by `automated.sh` before substitution. Also usable independently.

1. **Create script with standard boilerplate** — `set -euo pipefail`, color functions (`log`/`warn`/`error`/`die`) matching existing conventions
2. **Define schema as associative arrays:**
   - Required keys (must be present + non-empty): `DISK`, `ROOT_FS`, `TIMEZONE`, `LOCALE`, `KEYMAP`, `HOSTNAME`, `KERNEL`, `BOOTLOADER`
   - Optional keys (may be empty): `EFI_SIZE`, `SWAP_SIZE`, `ROOT_SIZE`, `LUKS`, `MICROCODE`, `GPU_DRIVER`, `DESKTOP_ENV`, `EXTRA_PACKAGES`, `USERNAME`, `AUR_HELPER`, `USE_REFLECTOR`, `REFLECTOR_COUNTRY`, `ENABLE_MULTILIB`, `ENABLE_AUTO_UPDATE`, `description`
   - Enum values for constrained fields: `ROOT_FS` → `ext4|btrfs|xfs`, `BOOTLOADER` → `systemd-boot|grub`, `KERNEL` → `linux|linux-lts|linux-zen|linux-hardened`, `LUKS`/`USE_REFLECTOR`/`ENABLE_MULTILIB`/`ENABLE_AUTO_UPDATE` → `true|false|""`, `MICROCODE` → `amd-ucode|intel-ucode|""`, `AUR_HELPER` → `yay|paru|""`
3. **Format validators** (functions):
   - `_validate_size_format()` — `EFI_SIZE`/`SWAP_SIZE`/`ROOT_SIZE`: `^[0-9]+(\.[0-9]+)?[KkMmGgTt]([Ii][Bb])?$` or empty
   - `_validate_disk_path()` — must match `^/dev/` (can't check `-b` since validation may run on a different machine)
   - `_validate_hostname()` — RFC 1123: `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$`
   - `_validate_username()` — `^[a-z_][a-z0-9_-]{0,31}$` or empty
   - `_validate_locale_format()` — `^[a-z]{2}_[A-Z]{2}\.[A-Za-z0-9-]+$`
   - `_validate_timezone_format()` — `^[A-Za-z_]+(/[A-Za-z_]+)*$`
   - `_validate_efi_minimum()` — if `EFI_SIZE` set, parse and verify ≥256MiB
4. **Cross-field dependency checks:**
   - `AUR_HELPER` set → `USERNAME` must be non-empty
   - `LUKS=true` → warn that `LUKS_PASSWORD` env var needed at runtime
5. **Unknown-key detection** — warn on any key not in required/optional lists (catches typos like `filesytem` instead of `ROOT_FS`)
6. **Error accumulation** — collect all errors, print together at end (not fail-fast). Exit 0 if clean, 1 if any errors
7. **CLI interface:**
   - `bash validate-config.sh config.json profile-name` — validate one profile
   - `bash validate-config.sh --all config.json` — validate every profile
8. **Integrate into `automated.sh`** — call before the `_subst` loop: `bash validate-config.sh "$CONFIG_FILE" "$CONFIG_NAME" || die "Config validation failed"`

---

### Phase 2: Post-Install Smoke Test

**New file:** `archlinux/installation/verify-install.sh`
**Modified:** `archlinux/installation/install.sh` (add `--verify` flag)

1. **Create `verify-install.sh`** — runs inside arch-chroot, uses `✔`/`✘` symbols (matching `update-check.sh` convention)
2. **Check functions** (each prints pass/fail, returns 0/1):

   | Check | What it verifies |
   |-------|-----------------|
   | `check_bootloader` | systemd-boot: `loader.conf` + `entries/arch.conf` exist with correct kernel; grub: `grub.cfg` exists |
   | `check_fstab` | `/etc/fstab` has root mount, `/boot` mount, btrfs `subvol=@` if applicable; `findmnt --verify` |
   | `check_initramfs` | `/boot/initramfs-$KERNEL.img` exists (>1MB), fallback image exists, `sd-encrypt` in HOOKS if LUKS |
   | `check_locale` | `/etc/locale.conf` contains `LANG=`, `locale -a` includes configured locale |
   | `check_timezone` | `/etc/localtime` is symlink to correct zoneinfo path |
   | `check_hostname` | `/etc/hostname` matches, `/etc/hosts` references it |
   | `check_services` | NetworkManager, display manager (sddm/gdm/lightdm based on DE), TPM service if LUKS |
   | `check_users` | User in `/etc/passwd`, sudoers drop-in exists (if USERNAME configured) |
   | `check_crypto` | `/etc/crypttab.initramfs` references cryptroot, keyfile exists for crypthome (if LUKS) |
   | `check_kernel` | `/boot/vmlinuz-$KERNEL` exists, microcode image exists if configured |

3. **Summary output:** `Post-install verification: 9/10 passed, 1 failed` with grid of results
4. **Config context passing:** `install.sh` sed-substitutes `__PLACEHOLDER__` tokens in `verify-install.sh` (same pattern as `chroot-setup.sh`) before copying to `/mnt/root/` and running via arch-chroot
5. **`--verify` flag in install.sh:**
   - Parsed alongside `--dry-run`
   - Runs after `configure_system()`, before `finish_install()`
   - Failures print warnings but **don't block reboot** — user decides
   - Can also be run standalone on an already-installed system (if `/mnt` is mounted)
6. **Pass-through from `automated.sh`** — `--verify` forwarded via `EXTRA_ARGS`

---

### Relevant Files

- `archlinux/config/install.json` — config being validated; field names and example values
- `archlinux/installation/automated.sh` — integrate validator call before `_subst` loop; reference `CONFIG_KEYS` array
- `archlinux/installation/install.sh` — add `--verify` flag; reference `preflight_checks()` for existing validation, `configure_system()` for sed pattern
- `archlinux/installation/chroot-setup.sh` — reference for what smoke test should verify
- `archlinux/tools/update-check.sh` — reference for `✔`/`✘`/`⚠` symbol convention

### Verification

1. Run `bash validate-config.sh archlinux/config/install.json minimal-vm` — should pass clean
2. Introduce `ROOT_FS: "btfrs"` typo → confirm clear error
3. Run `--all` flag → validates both existing profiles
4. Add unknown key `"filesytem": "btrfs"` → confirm warning
5. Set `AUR_HELPER: "yay"` with empty `USERNAME` → confirm cross-field error
6. Run `install.sh --verify` on QEMU VM after full install → all 10 checks pass
7. Deliberately break one (delete initramfs) → confirm `✘` output
8. `shellcheck validate-config.sh verify-install.sh` — zero warnings

### Decisions

- Validator is a **separate script** (not inline in `automated.sh`) for reuse and independent testing
- Smoke test runs **inside arch-chroot** to enable `systemctl`, `locale -a`, etc.
- Smoke test failures are **warnings, not blockers** — user can still proceed to reboot
- Config validator shows **all errors at once** (better UX for fixing multiple issues)
- `DISK` validated for format (`^/dev/`) but not block-device existence (validator may run off-target)
- Check symbols follow existing convention from `update-check.sh`
