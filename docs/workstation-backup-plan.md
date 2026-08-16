# Workstation Backup Plan

Status: **drafted 2026-08-15, not yet implemented**. Out of scope for `backup-dr-plan.md` (that
doc covers the cluster; this covers personal Linux workstations backing up *to* the NAS,
independent of Kubernetes). Runs entirely on `nas-ultan` and each workstation — nothing here
touches the cluster.

**Decision: Kopia**, replacing the current Pika/Borg-over-SSH setup. Reasoning: same tool
already run and understood for the cluster's backups (`kopiur`), native S3/B2 support if an
off-site leg gets added later (no `rclone` hop needed, unlike Borg), and KopiaUI is
flatpak-available as a GUI on par with Pika's convenience. Borg's one real edge — server-side
`--append-only` SSH restriction, so a compromised workstation can push new backups but can't
delete/tamper with old ones — gets replaced by **ZFS snapshots on the NAS-side dataset** instead
(§2), which protects the repo regardless of which backup tool writes to it and is arguably
stronger (immutable at the storage layer, not the application layer).

Each workstation gets its **own** Kopia repository (not the cluster's `nas-backups` repo — this
is personal data, different retention/purpose, no reason to share a password/namespace with
cluster backups) and its **own** restricted NAS user, so a compromised workstation's blast radius
is exactly that one user's chroot subtree.

---

## 1. NAS-side: one restricted SFTP-only user per workstation

OpenSSH's `ChrootDirectory` can only be set in `sshd_config` (via a `Match` block keyed on
user/group), not per-key in `authorized_keys` — so proper isolation between workstations means
**separate Unix users**, not one shared account with multiple keys. This is more setup than a
single shared user, but it's what actually enforces "workstation A's key can't touch workstation
B's backups," which was the point.

### One-time: group + chroot parent
```sh
# On nas-ultan, as root:
groupadd kopia-backup
mkdir -p /backups/workstations
chown root:root /backups/workstations
chmod 755 /backups/workstations   # chroot root must NOT be group/world-writable
```

### Per workstation (repeat for each host)
```sh
host=desktop   # substitute: desktop, laptop, etc.

useradd -m -d /backups/workstations/$host -s /usr/sbin/nologin -g kopia-backup $host-backup
mkdir -p /backups/workstations/$host/.ssh
chmod 700 /backups/workstations/$host/.ssh
chmod 700 /backups/workstations/$host
chown -R ${host}-backup:kopia-backup /backups/workstations/$host

# Paste that workstation's dedicated (not reused) ed25519 public key:
echo "ssh-ed25519 AAAA... $host" > /backups/workstations/$host/.ssh/authorized_keys
chmod 600 /backups/workstations/$host/.ssh/authorized_keys
chown ${host}-backup:kopia-backup /backups/workstations/$host/.ssh/authorized_keys
```

### `/etc/ssh/sshd_config.d/kopia-backup.conf`
```
Match Group kopia-backup
    ChrootDirectory %h
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
    PermitTunnel no
    PasswordAuthentication no
```
```sh
sshd -t   # validate syntax before reloading - a broken sshd_config can lock out ALL ssh access
systemctl reload sshd
```

**Test before trusting it:**
```sh
sftp -i ~/.ssh/id_ed25519_desktop_backup desktop-backup@nas-ultan
# should land chrooted at what NAS sees as /backups/workstations/desktop (shown as / to the client)
# confirm: cannot cd .. past root, cannot see other workstations' directories
```

Generate a **separate SSH keypair per workstation** (`ssh-keygen -t ed25519 -f
~/.ssh/id_ed25519_<host>_backup -C <host>`) rather than reusing one key everywhere — same
reasoning as separate NAS users: one compromised laptop shouldn't imply rotating every
workstation's credentials.

---

## 2. NAS-side: ZFS snapshots on the backup dataset (the ransomware-resistance piece)

Put workstation backups on their own dataset (not nested under the existing `/backups` export
used by kopiur/etcd/RGW-sync — separate retention policy, separate snapshot schedule, keeps blast
radius and dataset properties independent):

```sh
# Substitute your actual pool name (see docs/disk-hardware-plan.md §1).
zfs create -o mountpoint=/backups/workstations <pool>/backups-workstations
```

(If `/backups/workstations` from §1 already exists as a plain directory on the main pool, either
`zfs create` at that exact mountpoint after moving existing content aside, or pick a fresh
mountpoint and update §1's paths to match — do this **before** creating the per-workstation users,
not after, to avoid a mid-flight `chown`/permissions surprise from the dataset mount.)

**Snapshot schedule — recommend `zrepl`, not `sanoid`, run as a Podman Quadlet** (consistent
with `smartctl-exporter`/`node-exporter`/`alloy` on the same box — one operational model for
host-level services, not a one-off raw systemd unit). `nas-ultan` runs Flatcar, same as the k8s
nodes — no package manager, no Perl in the base image, so `sanoid` (a Perl script) is out. `zrepl`
does the same job (config-driven periodic snapshot + GFS pruning, no hand-rolled `zfs snapshot`/
`zfs destroy` cron logic) as a single static Go binary — and critically, it **shells out to the
`zfs`/`zpool` CLI rather than linking `libzfs` directly** (pure Go, no cgo), so the container
itself needs almost nothing of its own.

```yaml
# /etc/zrepl/zrepl.yml
jobs:
  - name: backups-workstations-snap
    type: snap
    filesystems:
      "<pool>/backups-workstations<": true   # trailing < = dataset + all children, recursive
    snapshotting:
      type: periodic
      interval: 1h
    pruning:
      keep:
        # Mirrors kopiur's own GFS retention (backup-dr-plan.md §2 L2) for consistency -
        # not load-bearing, just avoids inventing a third retention convention.
        - type: grid
          grid: 1x1h(keep=24) | 1x1d(keep=7) | 1x7d(keep=4) | 1x30d(keep=3)
          regex: "^zrepl_"
```

**The one real wrinkle vs. the other quadlets on this box:** `zfs`/`zpool` are tightly
version-coupled to the host's OpenZFS *kernel module* via ioctl ABI (confirmed live on
`nas-ultan`: `zfs-2.3.3-r0-gentoo`, and `/usr/bin/zfs` alone pulls in 18 shared libraries -
`libzfs.so.6`, `libzfs_core.so.3`, `libuutil.so.3`, `libnvpair.so.3`, plus libc/libcrypto/libkrb5/
etc.) — unlike SMART or `/proc`/`/sys` reads, a mismatched userspace-vs-kernel-module version can
fail outright or silently misbehave. Hand-enumerating 18 individual bind-mounts is fragile and
would silently go stale on the next `zfs` sysext update.

**The fix: bind-mount the host's entire `/usr` read-only, not individual binaries/libs.** The
`zfs` sysext already keeps `/usr/bin/zfs`/`zpool` and every library they need version-locked to
the kernel module automatically on every Flatcar update — mounting `/usr` wholesale inherits that
guarantee for free, forever, with zero image-rebuild-on-ZFS-upgrade maintenance. `zrepl` itself
(the static binary) lives outside `/usr` in the container so the host mount doesn't shadow it:

```
# /etc/containers/systemd/zrepl-backups-workstations.container
[Unit]
Description=zrepl - ZFS snapshot/pruning for workstation backups
After=zfs-setup.service

[Container]
Image=<build or pull a minimal image with just the static zrepl binary at /zrepl -
       see github.com/zrepl/zrepl/releases for the current stable version/binary>
Volume=/usr:/usr:ro
Volume=/dev/zfs:/dev/zfs
Volume=/etc/zrepl:/etc/zrepl:ro,Z
PodmanArgs=--privileged
Exec=/zrepl daemon -config /etc/zrepl/zrepl.yml

[Service]
Restart=always

[Install]
WantedBy=multi-user.target
```

No bind-mount of the actual `/backups/workstations` data tree needed — ZFS snapshots operate at
the pool/dataset level via `/dev/zfs` + the CLI, not by reading the mounted directory, so zrepl
never needs to see the backup files themselves.

**Why this covers what Borg's `--append-only` covered:** the workstation SSH user can read/write/
delete freely *within its own chroot*, including issuing a Kopia `maintenance`/prune that deletes
blobs from the live dataset. But it has no access to `zfs` commands or prior snapshots — those
exist one layer below what SFTP exposes. A compromised workstation (or a bad Kopia maintenance
run) can damage the *live* copy; the last N hourly/daily/weekly snapshots are still there,
untouched, restorable via `zfs rollback` or by browsing `.zfs/snapshot/<name>/` directly. This is
arguably stronger than Borg's append-only mode, which only stops deletion — a sufficiently buggy
or malicious client could still corrupt the append-only log itself; a ZFS snapshot is a
point-in-time block-level copy, immutable by construction.

---

## 3. Workstation-side: Kopia setup

```sh
# Flatpak, or your distro's package - either works, same underlying kopia binary.
flatpak install flathub io.github.kopia.KopiaUI

kopia repository create sftp \
  --path=/ \
  --host=nas-ultan \
  --username=${host}-backup \
  --keyfile=~/.ssh/id_ed25519_${host}_backup \
  --known-hosts=~/.ssh/known_hosts
```
(`--path=/` because the SFTP session is already chrooted to this workstation's own directory —
there's nothing else to see at `/`.) Set a strong repository password when prompted; store it in
your password manager, same as the sops age key convention for the cluster — **this password is
not backed up anywhere else**, losing it means losing the ability to decrypt this workstation's
backups.

Add source paths and a retention policy (same GFS numbers as §2's zrepl config, for one less
thing to remember) either via `kopia policy set` or KopiaUI once the repo is connected — KopiaUI
will pick up the same repository non-interactively after the CLI `repository create` step above.

---

## Open questions / not decided yet
- **Off-site (B2) for workstation backups** — deliberately not designed here per your own note
  that these are larger than the DB/app backups already going to B2. If wanted later: either a
  second Kopia repository pointed directly at a dedicated B2 bucket (native support, no NAS hop),
  or `rclone sync` of the NAS-side workstation dataset the same way `rgw-nas-sync` mirrors to
  `ceph-rgw-backups` today. Revisit once §1/§2 are live and you have a real sense of the data
  volume.
- **Which workstations** — this doc assumes at least `desktop` + `laptop`; substitute your actual
  hostnames throughout §1.
- **Migrating existing Pika/Borg history** — not addressed here. The existing Borg repo on the
  NAS can just keep existing read-only (or get deleted once you're confident in the new setup);
  no plan to import Borg archives into Kopia.
