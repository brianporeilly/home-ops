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

**Snapshot schedule — recommend `sanoid`** (config-file-driven, purpose-built for this, avoids
hand-rolling cron + `zfs snapshot`/`zfs destroy` retention logic):

```sh
# /etc/sanoid/sanoid.conf
[backups-workstations]
    use_template = production
    recursive = yes

[template_production]
    # Mirrors kopiur's own GFS retention (backup-dr-plan.md §2 L2) for consistency -
    # not load-bearing, just avoids inventing a third retention convention.
    hourly = 24
    daily = 7
    weekly = 4
    monthly = 3
    autosnap = yes
    autoprune = yes
```
Point sanoid at the workstation dataset specifically (adjust the section name to match whatever
you named it above), run it from cron/systemd-timer per its own install docs.

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

Add source paths and a retention policy (same GFS numbers as §2's sanoid config, for one less
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
