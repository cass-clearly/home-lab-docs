# Home Lab Runbook

Living documentation for Chris's media/home-lab setup. The goal is simple: if Cass disappears, Chris should still be able to operate, troubleshoot, move, and recover the stack.

Last updated: 2026-05-26

## 1. What this setup is

This is a Linux-hosted media stack running on the ai-server, with storage on a directly attached DAS.

Core pieces:
- **Host:** ai-server (Linux)
- **Storage:** 2-disk **Linux mdadm RAID1** on the DAS
- **Encryption:** **LUKS** on top of the RAID
- **Filesystem:** **ext4**
- **Primary mount:** `/mnt/das/data`
- **Compatibility symlink:** `/mnt/nas/data -> /mnt/das/data`
- **Media apps:** Plex, Seerr, Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent
- **Container platform:** Docker Compose

Mental model:
- disks -> mdadm RAID1 -> LUKS -> ext4 -> mounted media folders
- qBittorrent downloads
- Sonarr/Radarr decide what to grab/import
- Prowlarr provides indexers to Sonarr/Radarr
- Plex serves the finished library

## 2. Storage layout

### Physical/logical structure
Current array:
- **RAID device:** `/dev/md0`
- **Encrypted mapper:** `/dev/mapper/nas_crypt`
- **Mountpoint:** `/mnt/das/data`

Current storage design:
1. two disks presented by the DAS
2. Linux **mdadm RAID1** mirror built from disk partitions
3. **LUKS** encryption on top of the RAID
4. **ext4** filesystem inside the unlocked mapper
5. filesystem mounted at `/mnt/das/data`

### Capacity
Usable size is capped to the smaller RAID member, so the current usable volume is about **5.5 TB**.

### Important directories
Current canonical layout under `/mnt/das/data`:
- `torrents/incomplete/`
- `torrents/complete/`
- `media/Movies/`
- `media/TV Shows/`
- `media/Kids TV/`

Compatibility symlinks are intentionally still present:
- `/mnt/das/data/incomplete -> /mnt/das/data/torrents/incomplete`
- `/mnt/das/data/completed -> /mnt/das/data/torrents/complete`
- `/mnt/das/data/Movies -> /mnt/das/data/media/Movies`
- `/mnt/das/data/TV Shows -> /mnt/das/data/media/TV Shows`
- `/mnt/das/data/Kids TV -> /mnt/das/data/media/Kids TV`

The symlinks are there to preserve continuity for existing paths and recovery scripts while the apps move to the `/data/...` model.

### Why this matters
This is **Linux software RAID**, not enclosure RAID.
That means:
- recovery is easiest on **Linux**
- macOS will **not** just mount a single disk as a normal volume
- a recovery path exists, but it expects `mdadm` + `cryptsetup` + ext4 support

## 3. Encryption

Encryption is mandatory in this setup.

### How it works
- The RAID device is encrypted with **LUKS**.
- It unlocks to `/dev/mapper/nas_crypt`.
- ext4 lives inside that unlocked device.

### Recovery secret
The recovery passphrase is stored in 1Password under:
- **`AI Server NAS LUKS Recovery Passphrase`**

### Auto-unlock
Auto-unlock is configured via a keyfile on the host.
That means normal boots should assemble the array, unlock the LUKS device, and mount `/mnt/das/data` automatically.

## 4. Services and where they live

### qBittorrent
Purpose:
- torrent download client

Compose file:
- primary/non-VPN: `/home/cass/services/qbittorrent/docker-compose.yml`
- VPN test stack: `/home/cass/services/vpn-qb/docker-compose.yml`

Config path:
- `/home/cass/downloads/qbittorrent/config`

Important details:
- qB is normally reached by Arr at `qbittorrent:8081`
- when using the VPN stack, the `wireguard-qb` container joins `arr-stack_default` with Docker alias `qbittorrent` so Sonarr/Radarr do not need a host change
- Web UI on LAN: `http://192.168.5.204:8081`
- qB's internal torrent listen port is provider-dependent on the VPN stack and is **not published on the host**
- as of 2026-05-02 the AirVPN-backed `vpn-qb` stack is using forwarded port **55099 TCP/UDP**
- only the Web UI (`8081`) should be exposed on the host when qB is behind WireGuard
- qB is additionally bound to the WireGuard interface in config:
  - `Connection\InterfaceName=wg0`
  - `Connection\InterfaceAddress=` (left blank so qB follows whatever VPN address the active `wg0.conf` assigns)
- container now mounts the whole DAS root at `/data`
- qB save path now points at `/data/torrents/complete`
- qB temp path now points at `/data/torrents/incomplete`
- **critical permissions rule:** the qB container runs as UID/GID `1000:1000` (`abc:users` inside the container, `csalvato:csalvato` on the host). `/mnt/das/data/torrents/incomplete` must therefore be writable by host UID/GID `1000:1000` or qB will silently stall with `File error alert ... Permission denied` even when the VPN and trackers look healthy.
- quick validation after storage or VPN changes:
  - `sudo docker exec -u 1000:1000 qbittorrent sh -lc 'touch /data/torrents/incomplete/qb-write-test && rm /data/torrents/incomplete/qb-write-test'`
  - if that fails, fix with `sudo chown -R 1000:1000 /mnt/das/data/torrents/incomplete`
- current WireGuard client config lives at `/home/cass/services/vpn-qb/wireguard/wg_confs/wg0.conf`
- LAN access to the qB Web UI depends on a persistent route override in `wg0.conf`:
  - `PostUp = ip route replace 192.168.0.0/16 via 172.22.0.1 dev eth0`
  - `PostDown = ip route del 192.168.0.0/16 via 172.22.0.1 dev eth0 || true`
  - without that route, `http://192.168.5.204:8081` can time out even though `curl http://127.0.0.1:8081` still works locally on the host
- `wg0.conf` also carries a kill-switch on the VPN stack now:
  - allow replies to `172.22.0.0/16` (Docker bridge) and `192.168.0.0/16` (LAN) on `eth0`
  - reject other non-local traffic not going out `wg0` and not marked with WireGuard fwmark `51820`
  - reject all IPv6 egress with `ip6tables -I OUTPUT -j REJECT` and keep IPv6 disabled via container sysctls
  - this was added after proving that an unexpected `wg0` link drop otherwise fell back to the Metronet IP; after the hardening, both an interface-loss test and an explicit `wg-quick down` test blocked egress instead of leaking to the home IP, while restore brought traffic back to the VPN IP

### Arr stack
Compose file:
- `/opt/compose/arr-stack/docker-compose.yml`

Apps in the stack:
- **Seerr**: request and discovery front-end for Plex/Sonarr/Radarr
- **Sonarr**: TV automation
- **Radarr**: movie automation
- **Prowlarr**: indexers/search aggregation
- **Bazarr**: subtitles
- **Plex**: media server

### Plex client compatibility note
- On 2026-05-18, live troubleshooting showed Samsung/Tizen (TV 2021) playback halting on a 4K HEVC/HDR file when Plex left direct play and entered a subtitle/audio transcode path.
- The concrete failing pattern was: HEVC video + DTS audio + active SRT subtitles on the Tizen client. Plex stayed healthy, but the TV session hit buffering until playback was forced back to direct play.
- On 2026-05-25, `Percy Jackson and the Olympians` S01E01 stalled for the same general reason, but the uglier file-level version of it: the MKV had **many audio and subtitle streams all flagged as default**. Plex then tended to hand the Samsung client an unnecessary compatibility path (EAC3/Atmos audio transcode + subtitle handling) even though the server itself was healthy.
- Fix applied on 2026-05-25:
  - first fixed `S01E01`, then scanned the rest of the series and found `S01E02` had the same fully-broken default flags
  - proactively normalized **all of S01E01–S01E08** for consistency
  - remuxed each file **without re-encoding**
  - set the **English AAC stereo** track as the only default audio track
  - cleared **all subtitle default flags**
  - restarted `plexmediaserver`
  - retained backups alongside the originals as `*.pre-cassfix.bak.mkv`
- Practical mitigations:
  - prefer Direct Play / Original Quality on Samsung TV clients when possible
  - prefer AC3 / EAC3 / AAC audio over DTS for broadly compatible library copies
  - avoid subtitle burn / unnecessary subtitle transcode paths on Tizen when playback gets unstable
  - if one title alone is weird while Plex overall looks healthy, inspect the file’s stream defaults before blaming CPU/disk/network
  - `ffprobe -show_streams <file>` is the fastest way to spot “everything marked default” garbage
- Treat this as a client-compatibility issue first, not a blanket Plex-server failure.

### 2026-06-01 Plex episode-order mismatch note
- If Plex shows a long run of episodes as "off by one," check whether the source release **combined a multi-part special into one file** while Plex metadata expects separate parts.
- Concrete example: `Seinfeld` season 6 had a `S06E14` file that runs about **45 minutes**. That file is effectively a combined `Highlights of 100` special, while Plex metadata commonly expects it split as `S06E14` + `S06E15`.
- Result: every later file in that season can look shifted by one title even though Plex is matching against the filename exactly as given.
- Fast check: compare runtime around the first bad title. A suspiciously double-length earlier file usually exposes the real problem.
- Fix path: rename the combined file as a multi-episode file (for example `S06E14-E15`) and then renumber subsequent files to line up with the metadata source Plex is using.

### 2026-05-26 emergency space cleanup + Mr. Robot removal
- Symptom: Sonarr queue looked "stuck" with completed torrents that were not being removed from qBittorrent.
- Root cause was **not** a bad Sonarr setting. Sonarr already had `removeCompletedDownloads=true`, but `/mnt/das/data` was effectively full, so imports were landing in `importBlocked` with `Not enough free space` and the completed payloads stayed behind.
- Verified hot spots before cleanup:
  - `/mnt/das/data/media/TV Shows/Mr. Robot` -> about **356 GB**
  - `/mnt/das/data/torrents/complete/Mr.Robot.S04...` -> about **145 GB** duplicate payload
  - `/mnt/das/data/_cass_cleanup_trash_*` -> about **181 GB** total
- User-directed cleanup performed on 2026-05-26:
  - removed `Mr. Robot` from Sonarr (`series id 73`) so it would not re-grab after deletion
  - deleted `/mnt/das/data/media/TV Shows/Mr. Robot`
  - deleted `/mnt/das/data/torrents/complete/Mr.Robot.S04.BluRay.1080p.DTS-HD.MA.5.1.AVC.REMUX-FraMeSToR`
  - cleared old cleanup trash directories: `_cass_cleanup_trash_20260504-141730`, `_cass_cleanup_trash_20260504-141848`
  - forced Plex TV library refresh and emptied Plex trash for section `3` (`TV Shows`)
- Follow-on cleanup/tuning for `Curb Your Enthusiasm` on 2026-05-26:
  - measured the existing library at about **415 GB** in episode payloads / **441 GB** on disk
  - confirmed it was **not 4K**; the bloat came mostly from **1080p BluRay remux** episodes, many in the **4–10 GB per episode** range
  - created a series-specific Sonarr quality profile: **`Curb 1080p Small`**
  - that profile allows only **1080p HDTV / WEB-DL / WEBRip**, disables **Bluray-1080p** and **Bluray-1080p Remux**, and strongly prefers **x265 / WEB / under-30-GB** releases
  - deleted `/mnt/das/data/media/TV Shows/Curb Your Enthusiasm`
  - updated Sonarr series `23` to use the new profile and triggered a rescan + fresh series search
  - early grabs after the re-search were compact season packs like `Curb.Your.Enthusiasm.S01.1080p.WEBRip.x265` (~4.8 GB), `S02` (~4.9 GB), `S03` (~5.0 GB), and `S04` (~5.5 GB)
- Follow-on cleanup/tuning for `Battlestar Galactica (2003)` on 2026-05-26:
  - measured the existing library at about **565 GB**
  - confirmed it was dominated by **1080p BluRay remux** payloads (`53` remux episodes out of `72`)
  - created a series-specific Sonarr profile: **`Battlestar 1080p Small`**
  - this profile keeps **1080p only**, allows non-remux **Bluray-1080p / WEB-DL / WEBRip / HDTV-1080p**, disables **Bluray-1080p Remux**, and strongly favors **x265 / smaller releases**
  - deleted `/mnt/das/data/media/TV Shows/Battlestar Galactica (2003)` and retriggered Sonarr search while keeping the series monitored
  - Sonarr immediately started pulling compact replacements instead of remuxes, including season packs around **7.9 GB**, **9.6 GB**, and one larger-but-still-non-remux **1080p x265** pack around **31.9 GB**
- Global policy tuning on 2026-05-26:
  - set **`Penalize Remux` = `-1000` across all Sonarr quality profiles**
  - set **`Penalize Remux` = `-1000` across all Radarr quality profiles**
  - swept stale completed payloads from `/mnt/das/data/torrents/complete`, leaving only automation directories (`manual-complete-events`, `qb-hooks`)
- Post-cleanup result:
  - `/mnt/das/data` first recovered to about **681 GB free** after the Mr. Robot + trash cleanup, then to about **1.1 TB free** after deleting `Curb Your Enthusiasm`, and then to about **1.8 TB free** after deleting `Battlestar Galactica (2003)` plus stale completed payloads
- Operational lesson:
  - when Arr queue cleanup looks broken, always check `df -h /mnt/das/data` first
  - if Sonarr shows `importBlocked` + `Not enough free space`, the problem is disk pressure, not ordinary completed-download handling
  - completed torrent payloads can become duplicate space sinks once imports partially succeed and then stall
  - for catalog TV where storage efficiency matters more than archival quality, a series-specific constrained profile can prevent remux blowups without changing the rest of the library
  - if you want remuxes to remain technically allowed but rarely chosen, a very strong negative custom-format score works well as a global default in both Sonarr and Radarr
### Seerr
- Image: `seerr/seerr:latest`
- Config path: `/opt/compose/arr-stack/seerr`
- Web UI: `http://192.168.5.204:5055`
- Internal app URL: `http://192.168.5.204:5055`
- Bound Plex server: `Main Library` via `host.docker.internal:32400`
- Enabled Plex libraries: `Movies`, `TV Shows`, `Kids TV`
- Bound Radarr default: `Ultra-HD` -> `/data/media/Movies`
- Bound Sonarr default: `Ultra-HD` -> `/data/media/TV Shows`
- Notes:
  - Seerr was installed on 2026-04-12 using the official Docker Hub image after confirming the current published image name from the Seerr project README.
  - `host.docker.internal:host-gateway` is set so the Seerr container can reach host Plex cleanly.
  - Seerr was initialized by authenticating against the existing Plex account on this box, then wiring Plex/Sonarr/Radarr through the Seerr API.

### Plex database
Used to rebuild library inventory:
- `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db`

## 5. Media paths and app behavior

### Sonarr
Current app-level root folders:
- `/data/media/TV Shows`
- `/data/media/Kids TV`

Legacy compatibility mounts still exist in the container (`/tv`, `/kids-tv`), but the app records themselves were moved to `/data/media/...` on 2026-04-11.

### Radarr
Current app-level root folder:
- `/data/media/Movies`

Legacy compatibility mount still exists in the container (`/movies`), but the app records themselves were moved to `/data/media/...` on 2026-04-11.

### qBittorrent categories
Used so Sonarr/Radarr can track and import correctly:
- Sonarr -> `sonarr`
- Radarr -> `radarr`

### Download flow
1. Sonarr/Radarr search via Prowlarr indexers
2. winning release is sent to qBittorrent
3. qB downloads into `/data/torrents/incomplete` then promotes into `/data/torrents/complete`
4. Sonarr/Radarr import into final library paths
5. Plex sees imported files in the media library

### Why the `/data` topology matters
This stack was rebuilt away from the older split-path layout after qB/Arr state became inconsistent.

Current best practice on this box is:
- every media app mounts `/mnt/das/data` as `/data`
- torrent staging lives under `/data/torrents/...`
- final libraries live under `/data/media/...`

This preserves one coherent filesystem tree across qB, Sonarr, and Radarr and avoids the old class of “downloaded here, imported there, tracker state points somewhere else” bugs.

## 6. Quality/profile decisions

### Shared high-level rule
The standard quality profile is **Ultra-HD**, but it has been redefined to mean:
- prefer **2160p**
- fallback to **1080p**
- fallback to **720p**
- reject anything below **720p**
- upgrades allowed

### Sonarr
Most general TV is still on the broader profiles, but the storage-recovery pass added a stricter same-quality / smaller-encode bias for targeted cleanup work.
Current series count at the time of writing: about **58** after re-adding **Frasier** to Sonarr.

Sonarr custom-format scoring now biases toward:
- Plex-friendly WEB releases
- Plex-friendly audio
- **English audio when available**
- smaller files
- **HEVC/x265 when it is a cleaner encode choice**
- away from **REMUX** releases for replacement hunts
- away from obvious **AI-upscale / 60fps / RIFE / DirtyHippie** nonsense

The English-audio rule is a **preference, not a hard requirement**. Non-English releases can still be accepted when no English-audio option exists.

Storage-recovery execution on 2026-05-03:
- `Mr. Robot`, `The Office (US)`, and `Firefly` were moved to **HD-1080p** so Sonarr stops favoring oversized UHD-ish garbage for shows that should really just be good 1080p.
- `The Bear`, `The Mandalorian`, `Mythic Quest`, and `Percy Jackson and the Olympians` stayed on **Ultra-HD** with stricter scoring for saner encodes.
- `Frasier` was added back into Sonarr and placed on **HD-1080p** so it can participate in replacement searches instead of sitting unmanaged on disk.
- Episode searches were triggered for: `Mr. Robot`, `Frasier`, `The Office (US)`, `Firefly`, `The Bear`, `The Mandalorian`, `Mythic Quest`, and `Percy Jackson and the Olympians`.
- Later that same night, Chris decided `Mythic Quest` should be removed entirely rather than downsized. The Sonarr series entry was deleted and the orphaned on-disk library folder was manually removed after Sonarr failed to clean the files. That reclaimed roughly **90 GB**, taking free space from about **236 GB** to about **322 GB**.
- Later that same night, Chris asked for a harder reset on `Mr. Robot` and `Firefly`: both were removed from the library and from Sonarr, the leftover on-disk payloads were manually deleted after Sonarr again failed to fully clean files, and both series were re-added fresh. `Mr. Robot` was re-added on **HD-1080p** to bias toward smaller sane encodes. `Firefly` was re-added on **Ultra-HD** so 2160p remains preferred, but with the smaller-file / anti-remux / anti-AI-upscale scoring still in effect. That jump took free space to about **1006 GB**.

Notably, **no TV-specific 3D rule** was added.

### Radarr
All movies were assigned to **Ultra-HD**.
Current movie count at the time of writing: about **230**.

Radarr custom-format scoring on Ultra-HD is intentionally biased toward compressed, Plex-friendlier releases:
- **No 3D** = `-10000`
- **Prefer Under 15 GB** = `+75`
- **Prefer Under 30 GB** = `+50`
- **Penalize Over 30 GB** = `-75`
- **Prefer Plex-Friendly WEB** = `+40`
- **Prefer Plex-Friendly Audio** = `+20`
- **Prefer HEVC/x265** = `+25`
- **Prefer English Audio** = `+100`
- **Penalize Plex-Unfriendly Disc/ISO** = `-175`
- **Penalize Remux** = `-250`

The same general bias was also applied to the 1080p-oriented movie profiles, with **Prefer Under 5 GB** = `+75` and **Prefer English Audio** = `+100`.

Storage-recovery execution on 2026-05-03 also kicked off a focused movie replacement pass for:
- `Star Wars: Episode I - The Phantom Menace`
- `The Shining`
- `Monsters University`
- `Titanic`
- `Anora`
- `Dune (2021)`
- `Jumanji (1995)`
- `The Sound of Music`
- `Spirit: Stallion of the Cimarron`
- `The Matrix Reloaded`
- `Independence Day`
- `Stardust`
- `Aladdin (2019)`
- `Avatar (2009)`

`Spirit: Stallion of the Cimarron` was re-monitored in Radarr before the search so it would actually participate.

Radarr quality-profile language was changed from **Original** to **Any**, so English audio is now a strong preference rather than a hard original-language bias.

Meaning:
- prefer 4K when sane
- prefer compressed WEB / HEVC encodes over giant disc-like releases
- strongly discourage remuxes and full-disc/ISO garbage
- prefer English audio when available, but still allow foreign-language-only titles as fallback
- prefer normal client-friendly audio where possible
- discourage massive movie files where possible

## 7. Current indexers

Current enabled Prowlarr indexers:
- 1337x
- EZTV
- LimeTorrents
- Nyaa.si
- Shana Project
- SubsPlease
- The Pirate Bay
- Tokyo Toshokan
- TorrentGalaxy

Disabled as low-value for TV:
- YTS

Notes:
- anime-related sources are mainly for anime/Japanese content
- general English TV/movie usefulness mainly comes from 1337x, EZTV, LimeTorrents, TPB, TorrentGalaxy
- better long-tail coverage would likely come from private trackers

## 8. qBittorrent tuning

Current queueing behavior:
- queueing enabled: `true`
- **max active downloads:** `5`
- **max active torrents:** `6`
- **max active uploads:** `1`

This was intentionally limited to avoid flooding the box with too many active grabs at once.

### Why speeds may fluctuate
If all active torrents rise/fall together, likely shared bottlenecks are:
- network path instability
- storage IO / USB / RAID / encryption overhead
- qB global pacing / connection behavior

If one torrent behaves differently from another, that is more likely peer quality.

### 2026-04 / 2026-05 qB completion cleanup behavior

First we had this problematic combination:
- `Session\GlobalMaxRatio=0`
- `Session\ShareLimitAction=Stop`

That made a torrent hit its share limit immediately on completion and get **stopped**, which left finished items cluttering qB for hours.

On 2026-04-16 that was changed to:
- `Session\GlobalMaxRatio=0`
- `Session\ShareLimitAction=Remove`

That cleaned up the qB list, but it created a worse side effect discovered on 2026-05-03:
- a torrent with ratio limit `0` and action `Remove` is removed from qB essentially **immediately when it completes**
- Sonarr/Radarr often lose the completed-download context before their import pass runs
- result: payloads pile up in `/mnt/das/data/torrents/complete` and never auto-move into the library

Observed symptom pattern:
- Sonarr/Radarr parsing sees the release while downloading
- qB no longer has the torrent in its active list once complete
- manual import/scan succeeds later
- `torrents/complete` accumulates stranded folders/files

Fix applied on 2026-05-03, then refined on 2026-05-03 after Chris asked for downloads to stop seeding and stop lingering as library+completed twins:
- set `Session\GlobalMaxRatio=-1`
- set `Session\GlobalMaxSeedingMinutes=1`
- set `Session\ShareLimitAction=Stop`
- set Sonarr `copyUsingHardlinks=false`
- set Radarr `copyUsingHardlinks=false`

Operational meaning now:
- qB keeps a very short post-complete grace window (~1 minute) so Arr still has time to import cleanly
- Arr imports by real copy/move behavior instead of hardlinking into the library
- qB stops seeding instead of auto-removing the torrent out from under Arr
- after import, the desired steady state is library file only; if a stopped completed payload lingers, that is cleanup drift worth checking

Verification after the refinement:
- qB config shows `Session\GlobalMaxRatio=-1`
- qB config shows `Session\GlobalMaxSeedingMinutes=1`
- qB config shows `Session\ShareLimitAction=Stop`
- Sonarr/Radarr media-management config shows `copyUsingHardlinks=false`
- stranded backlog in `torrents/complete` was manually cleared/imported on 2026-05-03

If this behavior regresses, check these first:
1. `Session\GlobalMaxRatio` is **not** `0`
2. `Session\GlobalMaxSeedingMinutes` is set (currently `1`)
3. `Session\ShareLimitAction=Stop`
4. Sonarr/Radarr media management still has `copyUsingHardlinks=false`
5. Sonarr/Radarr still have completed download handling enabled

Important: if you edit qB config by hand, prefer doing it with qB stopped; otherwise qB can write its in-memory settings back during shutdown and undo the change.

## 9. Networking

### qB inbound port
For better torrent connectivity, the host should forward:
- **6881 TCP** -> ai-server (`192.168.5.204`)
- **6881 UDP** -> ai-server (`192.168.5.204`)

Do **not** forward admin UIs publicly:
- 8081 (qB Web UI)
- 8989 (Sonarr)
- 7878 (Radarr)
- 9696 (Prowlarr)
- 5055 (Seerr)

Those should remain LAN-only unless intentionally reverse-proxied behind auth.

### Web UI access
qBittorrent Web UI:
- `http://192.168.5.204:8081`

Seerr:
- `http://192.168.5.204:5055`
- Works well in a phone browser, and on iPhone/Android you can add it to the home screen as a pseudo-app.

## 10. Health monitoring

Health-check script:
- `/usr/local/sbin/check-nas-health`

Cron:
- `*/30 * * * * /usr/local/sbin/check-nas-health`

Purpose:
- check RAID/storage health regularly
- surface issues before they become data-loss problems

## 11. How to verify the stack after a reboot or move

After any shutdown, reboot, or physical move, verify in this order:

1. **RAID assembled**
   - check `/dev/md0`
2. **LUKS unlocked**
   - check `/dev/mapper/nas_crypt`
3. **filesystem mounted**
   - confirm `/mnt/das/data`
4. **containers are up**
   - qBittorrent, Sonarr, Radarr, Prowlarr, Bazarr, Plex
5. **qB Web UI loads**
   - `http://192.168.5.204:8081`
6. **Sonarr/Radarr/Prowlarr healthy**
7. **downloads resume**
8. **imports continue into Movies / TV Shows**

If the DAS does not come up cleanly, the media stack may start but behave badly because `/mnt/das/data` is the critical dependency.

## 12. Recovery / migration notes

### If the ai-server dies
Best recovery path:
1. move the DAS disks to another **Linux** machine
2. install/use:
   - `mdadm`
   - `cryptsetup`
   - ext4 support
3. assemble the RAID
4. unlock the LUKS device using the key/passphrase
5. mount the filesystem
6. restore Docker Compose services/configs

### If only one RAID member survives
Because this is RAID1, a single surviving member should usually be enough to recover the volume on Linux, using mdadm + LUKS tools.

### If you plug a member into a Mac
Do **not** expect Finder to show a normal volume.
macOS does not natively understand this stack as a plug-and-play disk.

## 13. Known issues / caveats

### qB API oddities
On this qB build, some automation endpoints were unreliable:
- pause/resume/force-start attempts returned 404 from scripts in earlier testing
- listing, delete, priority changes, and preference updates worked

Practical implication:
- some queue hygiene may be easier in the UI than via automation

### Radarr bulk search bug
Known error path:
- `Error occurred while executing task MoviesSearch: Value cannot be null. (Parameter 'source')`

Per-movie searches do work.

### qB / Sonarr / Radarr handoff edge cases
At times a torrent can appear effectively complete but still sit in an in-between state before import cleanup finalizes.
This is not always fatal, but it is something to watch when items seem stuck in “Moving” or “Downloading” with `sizeleft: 0`.

Separate from that, a torrent stuck at **99.8% to 99.9%** with:
- no `completed_time`
- incomplete-state payload still in `/mnt/das/data/torrents/incomplete`
- `num_complete = 0`

is usually a genuine swarm-availability problem, not a move/import problem. In that case qB is still missing the last piece and there may simply be no full seeder online.

### 2026-04 preventive audit findings
Current audit highlights:
- qB can run either directly on `arr-stack_default` or behind the WireGuard namespace stack in `/home/cass/services/vpn-qb`.
- shared container-visible paths are still the correct model here:
  - qB completed: `/downloads`
  - Sonarr libraries: `/tv` and `/kids-tv`
  - Radarr library: `/movies`
- `Remote Path Mapping` is correctly empty in both Sonarr and Radarr for this setup.
- `Completed Download Handling` is enabled in both Sonarr and Radarr.
- qB categories are correctly split:
  - Sonarr -> `sonarr`
  - Radarr -> `radarr`
- during the 2026-04-23 VPN retest, Arr connectivity was healthy again once the `qbittorrent` alias pointed at the WireGuard container and qB was restarted after the tunnel fix.
- on 2026-04-26 the VPN stack was switched from the prior WireGuard peer to a Proton VPN free WireGuard config (`CA-FREE#19`); qB/Arr reachability stayed healthy, and Proton free still means **no port forwarding**, so keep `PortForwardingEnabled=false` in qB unless the provider plan changes.
- on 2026-05-02 the `vpn-qb` stack was migrated again to **AirVPN** using the AirVPN config generator and a preserved local-LAN/kill-switch `PostUp`/`PostDown` policy in `wg0.conf`; verified results were:
  - `wg0` inside qB came up as `10.152.128.205/32`
  - public egress changed to `184.75.208.170`
  - AirVPN remote port forwarding was enabled on **55099/TCP+UDP**
  - qB listened on `10.152.128.205:55099` for both TCP and UDP while remaining bound to `wg0`
- on 2026-05-02 a follow-up optimization pass moved the stack from the generic America profile to the **Torcular** AirVPN server in **Denver, Colorado** (`Endpoint = 198.54.128.117:1637`) to improve locality/throughput without weakening privacy.
  - verified public egress after the change: `198.54.128.139`
  - repeated fail-closed test still passed: bringing `wg0` down blocked Internet egress from the qB namespace until the tunnel came back

Operational rule:
- if Sonarr/Radarr health shows `Unable to communicate with qBittorrent. Failed to authenticate with qBittorrent.` or `Connection refused (qbittorrent:8081)`, treat that as a real blocker for future automation and fix it immediately before relying on new grabs/imports.

### 2026-04 completed-folder cleanup lessons
When reconciling stranded payloads from `/mnt/das/data/completed`:
- prefer `rsync --ignore-existing` into the final library path first, then verify file counts before treating the staging copy as redundant
- if Sonarr/Radarr already have the title, run a targeted rescan/refresh after manual copies so app state catches up with disk state
- when orphaned manual import returns zero candidates but the title/episode/movie mapping is known-good, a reliable fallback is to place the file directly into the canonical final library path and rescan
- use **container-visible paths** in Arr API/manual-import workflows (`/downloads`, `/tv`, `/kids-tv`, `/movies`), not host paths like `/mnt/das/data/...`
- dot-prefixed leftovers and `.<name>.mkv.*` scratch files are safe to remove only after the corresponding final media file exists cleanly
- some bad grabs land as **txt-only** release folders (for example MgB-style movie folders containing only `Subtitle,info/Downloaded from 1337x.to.txt` and no media file); those can be treated as stale garbage and moved to a recoverable trash folder instead of leaving them in `completed/`
- `completed/` should be treated as a staging area, not a long-term archive; once files are safely landed in the final library, clear redundant completed copies conservatively
- for Kids TV migrations, copying the already-verified library payload into `/mnt/das/data/Kids TV` can be faster and safer than re-importing from a messy completed release tree
- broad/folder-wide Sonarr manual-import calls on historical orphan packs were brittle; per-file or small targeted handling was safer until canonical placement + rescan became the better fallback
- on 2026-05-03, duplicate-library cleanup confirmed that the only real duplicate TV payloads were an old `Frasier._archive_2026-04-14` folder (46 episodes, ~16.3 GiB) and one malformed `The Office (US)` Season 6 file (`The.Office.S06E0013...mp4`, ~0.46 GiB). The only duplicate movie payload found was `How to Train Your Dragon (2025)`, where the larger 11.82 GiB IMAX file was removed and the smaller 3.90 GiB WEBRip was kept per Chris's preference to minimize space.
- on 2026-05-04, stale qB incomplete payloads were cleaned by comparing `/mnt/das/data/torrents/incomplete` top-level entries against qB session state in `/home/cass/downloads/qbittorrent/config/qBittorrent/BT_backup/*.fastresume`; keep only entries whose torrent still had `completed_time=0`, `paused=0`, and `save_path` under `incomplete`. That pass removed 24 stale entries (mostly abandoned `Mr. Robot` remux seasons plus dead movie grabs like `Dune`, `The Matrix`, `Avatar 3D`, and `Pulp Fiction`) and left only currently active incomplete payloads on disk.
- later on 2026-05-04, Plex movie-library cleanup compared the on-disk movie folders in `/mnt/das/data/media/Movies` against the live Radarr `/api/v3/movie` list and removed 35 orphaned movie folders that Radarr no longer tracked. The orphan set totaled about **304 GiB**, and the movie library folder count dropped from 208 to 173 to exactly match Radarr again.
- later on 2026-05-04, Radarr was hardened further against oversized low-value movie grabs by adding a custom format named `Penalize AI Upscale/60fps` with regex `(?i)(AI[ ._-]?(UPSCALE|UPSCALED|ENHANCED)|RIFE|\b60FPS\b)` and score `-300` across all quality profiles. After that, the current obvious dumb-format movie offenders over ~20 GiB (`Jumanji`, `The Sound of Music`, `Spirit: Stallion of the Cimarron`, `Ice Age: Dawn of the Dinosaurs`, and `Toy Story 2`) were deleted from the library and per-movie `RefreshMovie` + `MoviesSearch` commands were queued in Radarr so saner replacements could be fetched under the updated rules.
- follow-up pass on 2026-05-04 found three remaining sub-20 GiB dumb-format tracked movie files: `Bad Santa` (9.26 GiB AI upscale), `Cool Runnings` (18.54 GiB remux), and `Puss in Boots: The Last Wish` (3.41 GiB remux/reencoded). `Cool Runnings` had to be re-monitored first, then all three existing files were removed, their stale Radarr `movieFile` records were deleted, and fresh per-movie searches were re-queued. Radarr immediately grabbed replacements for all three (`Bad Santa 2003 Unrated 1080p BluRay DD+ 5.1 x265-EDGE2020`, `Cool Runnings 1993 1080p BluRay DD+ 5.1 x265-edge2020`, and `Puss In Boots The Last Wish 2022 Bluray 2160p AV1 HDR10 EN/FR/ES OPUS 7.1-UH`).
- later on 2026-05-04, an orphaned `The.Greatest.Showman.2017.2160p.UHD.BluRay.x265-EMERALD` leftover was deleted from `torrents/complete` (~13.9 GiB). Then a broad Radarr storage-recovery pass removed every remaining tracked movie file over **20 GiB** (22 titles totaling about **611 GiB**). The pass initially triggered some bad duplicate/oversized grabs, so queue cleanup was required: blocklist the nonsense (`RiffTrax`, AI-upscaled, same-size 4K regrabs, and any duplicate larger candidate), then keep or manually trigger the smallest sane replacement under ~20 GiB. A few stubborn titles (`Titanic`, `Avatar`, and `Pirates of the Caribbean: The Curse of the Black Pearl`) were pinned to the `HD-1080p` profile to stop repeated jumbo 4K regrabs. After queue cleanup, there were no remaining queued movie grabs over 20 GiB or matching the bad-term filters, and RAID free space rose to about **2.0 TB**.
- later on 2026-05-04, a second cleanup pass handled Arr items stuck in completed-download state. The safe pattern on this box was:
  - inspect Arr queue first via `/api/v3/queue?page=1&pageSize=500&includeUnknownMovieItems=true&includeUnknownSeriesItems=true`
  - inspect per-folder candidates with `GET /api/v3/manualimport?folder=/data/...`
  - when the target library folders are root-owned, do the actual replacement move with `sudo`; non-root moves into `/mnt/das/data/media/...` can fail with `Permission denied`
  - move the old library payload to a recoverable stash before replacing it; this run used `/mnt/das/data/_cass_cleanup_trash_20260504-141855`
  - refresh Arr after disk changes with `RefreshMovie` / `RefreshSeries`
  - delete the matching qB torrents through the WebUI API from inside the container (`/api/v2/torrents/delete` with `deleteFiles=false`) once the new library copies are in place
- that 2026-05-04 pass finished with **11 movies** replaced/imported, **264 TV episode files** replaced/imported, matching qB hashes removed, and both Arr queues back to zero stuck completed items (`radarr stuck_count 0`, `sonarr stuck_count 0`). It intentionally included the requested `Frasier` downgrade swap plus `The Office (US)` Season 1 extended-cut replacements.

### 2026-04 RAID member replacement / rebuild incident
Observed state during the incident:
- `/proc/mdstat` showed `/dev/md0` in degraded recovery state (`[2/1] [_U]`)
- array recovery progressed slowly over many hours
- the correct verification commands were:
  - `cat /proc/mdstat`
  - `mdadm --detail /dev/md0`

What “healthy again” looks like:
- mdadm reports the array as `clean`
- both members are active
- `/proc/mdstat` shows `[UU]`

Operational rule:
- while rebuild is in progress, do not assume the array is failed if one member is missing from the active set
- treat it as an active rebuild unless progress stalls or mdadm reports a failed member
- keep the recurring rebuild-status check running until md0 is fully clean with both members active, then remove that temporary cron

## 14. Operational habits that matter

### For oversized movie grabs
Best cleanup flow:
1. remove the oversized torrent from qB
2. clear the associated grab/queue state in Radarr if needed
3. re-run search
4. let Radarr pick again under the current scoring rules

Do not assume deleting from qB alone is enough.

### For indexers
More indexers is not always better.
Prefer a smaller set of decent sources over a huge pile of junk.
Private trackers are likely the next meaningful quality step.

### For Sonarr / Radarr path hygiene
Preventive habit:
- series and movie paths stored in Sonarr/Radarr should point to real directories on disk
- missing paths do not always break day-to-day imports, but they can break manual import and make recovery work much harder
- after bulk library rebuilds or root-folder changes, run a quick audit for:
  - missing Sonarr series paths
  - missing Radarr movie paths
  - unexpected unmapped folders reported under root folders

### For qB authentication drift
If qB credentials are changed:
1. update the qB Web UI password
2. update the stored secret source of truth
3. immediately update both Sonarr and Radarr download-client settings
4. confirm Arr health is clean again

Do not assume fixing qB alone is enough. Sonarr and Radarr can silently remain broken until their stored credentials are updated too.

### For tracker discovery
A recurring reminder exists to check for private tracker openings/invites.
Current target trackers:
- TorrentLeech
- FileList
- IPTorrents
- AlphaRatio
- PrivateHD / BLU

## 15. File locations worth knowing

- qB compose: `/home/cass/services/qbittorrent/docker-compose.yml`
- qB config: `/home/cass/downloads/qbittorrent/config`
- Arr compose: `/opt/compose/arr-stack/docker-compose.yml`
- Prowlarr DB: `/opt/compose/arr-stack/prowlarr/prowlarr.db`
- Plex DB: `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Plug-in Support/Databases/com.plexapp.plugins.library.db`
- health script: `/usr/local/sbin/check-nas-health`
- media mount: `/mnt/das/data`
- compatibility symlink: `/mnt/nas/data`

## 16. What should be kept up to date

This file should be updated whenever any of these change:
- storage layout
- mountpoints
- RAID/encryption scheme
- Docker compose locations
- qB listen/web ports
- Sonarr/Radarr root folders
- quality profile strategy
- custom-format scoring
- indexers
- health-check scripts/cron
- recovery procedures

## 17. One-paragraph summary

This home lab is a Linux media stack running on ai-server with Docker-hosted Plex/Sonarr/Radarr/Prowlarr/Bazarr/qBittorrent, backed by a directly attached two-disk mdadm RAID1 array encrypted with LUKS and mounted at `/mnt/das/data`. qBittorrent handles downloads, Sonarr/Radarr automate grabs and imports, Prowlarr feeds indexers, Plex serves the final library, and the system is tuned to prefer 4K with sane fallbacks and Plex-friendly formats while avoiding 3D, disc/ISO junk, and oversized movie releases where possible.
