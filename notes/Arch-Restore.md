# Arch Restore — Home Server Migration Cheat-Sheet

> Companion to [[Bootstrap]]. Use this when reinstalling the Home Server on **Arch Linux**.
> Always mount `/mnt/storage` **before** running bootstrap (`setup_storage` mounts the wrong partition on a fresh Arch boot — see bug below).

---

## 1. Install Arch (archinstall)

- **Select ONLY `/dev/sda`** (Secureye SATA SSD) as the system disk.
- **NEVER touch `/dev/sdb` (TOSHIBA HDD) or `/dev/sdc` (WD external backup).** All persistent data lives on sdb2.
- Recommended layout on the SSD: `/`, `/tmp`, `/var`, `/home`, swap.
- Packages to install along with base: `networkmanager openssh git curl base-devel`.

---

## 2. Post-install: mount persistent storage

```bash
# Add to /etc/fstab BEFORE running bootstrap:
UUID=ef4c5fd2-8174-41c1-b05f-3e4cfbdf5091  /mnt/storage  ext4  defaults,nofail  0  2

sudo mkdir -p /mnt/storage
sudo mount -a
ls /mnt/storage  # expect: backups music navidrome nextcloud minecraft
```

Foreign text (e.g. the old OS) won't block you; sdb2 is ext4, label `HDD_Storage`.

### ⚠️ Known bootstrap bug (setup_storage)
`bootstrap.sh` picks the **first partition on /dev/sdb**, which is the **260M vfat `SYSTEM` partition (sdb1)** — not your data (sdb2). Workaround: mount sdb2 in `/etc/fstab` **first** (step above) so `setup_storage` sees `/mnt/storage` already mounted and skips.

---

## 3. Homelab bootstrap (the repo does everything on Arch)

```bash
# 1. Tailscale
curl -sfL https://tailscale.com/install.sh | sh
sudo tailscale up

# 2. Repo
git clone https://github.com/k0u3h1k/home_server-setup.git
cd home_server-setup

# 3. Bootstrap (idempotent, Arch-aware → uses pacman)
sudo ./bootstrap.sh
```

Expected result: K3s node `Ready`, databases namespace with MariaDB + Redis,
Nextcloud, Navidrome, Glance, Minecraft compose + scripts, Playit, display services.

**Arch notes:**
- Arch ships nftables by default; K3s needs iptables tools: `sudo pacman -S iptables-nft` if bootstrap complains.
- `ufw` (firewall) is in `extra` — bootstrap installs it via pacman.
- Tailscale hostname becomes whatever you set; MagicDNS domain stays `tailb96c63.ts.net`.

---

## 4. Restore MariaDB dump (Nextcloud metadata)

Dump was made to `/mnt/storage/backups/mariadb/mariadb-full-<timestamp>.sql`.

```bash
# After MariaDB pod is Running:
kubectl exec -n databases mariadb-0 -- sh -c 'cat > /tmp/dump.sql' < /mnt/storage/backups/mariadb/mariadb-full-*.sql
kubectl exec -n databases mariadb-0 -- sh -c 'ROOTPW=$(cat $MARIADB_ROOT_PASSWORD_FILE); mysql -uroot -p"$ROOTPW" < /tmp/dump.sql'
```

Then fix Nextcloud:

```bash
kubectl exec -n nextcloud deploy/nextcloud -- php occ maintenance:repair
kubectl exec -n nextcloud deploy/nextcloud -- php occ files:scan --all
```

---

## 5. Re-install Samba (Finder shares)

Samba is not installed by bootstrap. Do it once:

```bash
sudo pacman -S samba
nano /etc/samba/smb.conf   # paste from dotfiles/ ... or repo copy
sudo smbpasswd -a "$USER"
sudo systemctl enable --now smbd nmbd
```

Share config lives at `dotfiles/samba/smb.conf` in this repo (music, nextcloud,
minecraft, backups, storage).

```bash
sudo pacman -S samba
sudo cp ~/home_server-setup/dotfiles/samba/smb.conf /etc/samba/smb.conf
sudo smbpasswd -a "$USER"
sudo systemctl enable --now smbd nmbd
```

---

## 6. Verify everything

| Check | Command |
|-------|---------|
| Cluster | `kubectl get nodes && kubectl get pods -A` |
| DBs | `kubectl get pods -n databases` |
| Subsonic/Feishin | `https://<host>.tailb96c63.ts.net:4533` |
| Glance | `https://<host>.tailb96c63.ts.net:4443` |
| Nextcloud | `https://<host>.tailb96c63.ts.net:8443` |
| Minecraft | `cd apps/minecraft-docker && ./status.sh` |
| SMB | `find`er → ⌘K → `smb://<tailscale-ip>` |

---

## Backup / Restore responsibilities

| Data | Location | Survives Arch reinstall? | Needs backup? |
|------|----------|--------------------------|---------------|
| Songs (Navidrome) | HDD sdb2 `/mnt/storage/music` | ✅ Yes (untouched) | Copy made to WD external |
| Navidrome db | HDD sdb2 `/mnt/storage/navidrome` | ✅ Yes | Copy made to WD external |
| Nextcloud files | HDD sdb2 `/mnt/storage/nextcloud` | ✅ Yes | Copy made to WD external |
| Minecraft world | HDD sdb2 `/mnt/storage/minecraft` | ✅ Yes | Copy made to WD external |
| **MariaDB (Nextcloud db)** | **SSD sda K3s local-path** | ❌ **LOST** | ✅ Dumped to backups/ |
| **Redis cache** | **SSD sda K3s local-path** | ❌ LOST (regenerates) | No |
| K8s manifests | Rolled by Helm from repo | ✅ Recreated | — |
| /etc/hosts, fstab | — | ❌ LOST | Recreated by bootstrap |

---

## Quick reference

- Storage HDD: `/dev/sdb2` (ext4, label `HDD_Storage`, UUID `ef4c5fd2-8174-41c1-b05f-3e4cfbdf5091`)
- Backup drive: `/dev/sdc1` (ext4, label `Backup`) — mount at `/mnt/backup`
- Tailnet: `tailb96c63.ts.net`, MagicDNS hostname e.g. `homeserver`
- Repo: `https://github.com/k0u3h1k/home_server-setup`