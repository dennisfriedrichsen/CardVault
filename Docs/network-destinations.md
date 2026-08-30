# Network destinations

CardVault accepts a mounted NFS or SMB share as any destination, Primary included. This is the
contract for what it can and cannot tell about one, and why the rules are drawn where they are.

Mounting is out of scope. The user mounts the share in Connect to Server; CardVault sees an ordinary
path under `/Volumes` and needs no additional entitlement to reach it.

## What a share reports about itself

Measured on a MacBook Pro against one NAS exporting three NFS datasets and one SMB share:

| fact | `/Volumes/files-photos` | `/Volumes/photos-fast` | `/` (APFS) |
| --- | --- | --- | --- |
| `DADiskGetBSDName` | **nil** | **nil** | `disk3s1s1` |
| `.volumeUUIDStringKey` | **nil** | **nil** | `D3DC36BE-…` |
| `.volumeIsLocalKey` | false | false | true |
| `statfs.f_fstypename` | `nfs` | `smbfs` | `apfs` |
| `statfs.f_mntfromname` | `mercury.local:/mnt/tank/files-photos` | `//denny@mercury.local/photos-fast` | `/dev/disk3s1s1` |
| `statfs.f_fsid` | `436207624,2` | `905969674,30` | `16777235,26` |

Two consequences run through everything below.

**Disk Arbitration never describes a share.** `DADiskCopyDescription` does return a dictionary — it
even sets `DAVolumeNetwork=1` — but `DADiskGetBSDName` returns nothing, because there is no device to
name. `DiskArbitrationTopologyProvider` guards on a non-empty BSD name and therefore always throws for
a share, so nothing Disk Arbitration knows about a network mount can ever reach a `VolumeTopologyNode`.
The node used to carry an `isNetwork` field for this; it was unreachable and has been removed rather
than left looking authoritative.

**`f_mntfromname` is the only fact that names the server.** It is public, needs no privilege, and is
read through `MountFacts` into `NetworkVolumeOrigin` (host, export path, filesystem type).
`f_fsid` distinguishes mounts and says nothing about shared origin — the three NFS mounts above have
three different ones — so it is not used.

## Identity, and the line it does not cross

`NetworkVolumeOrigin` is deliberately not a `physicalStoreIdentifier`. The existing rule that a
fallback-resolved identity may not claim two paths share a physical device is unchanged; this is a
different claim, about a machine rather than a disk.

`VolumeIdentity.relation(to:)` reads it as follows.

- **Same host, same export → `.sameVolume`.** One export mounted twice is one directory tree under
  two names. Nothing else notices this: the two mount points really are different folders on this
  Mac, so the destination-overlap check passes them.
- **Same host, different export → `.sameServer`.** One machine serves both. Not one volume, and not
  two independent copies either.
- **Different host → `.indeterminate`, never `.distinct`.** This compares the strings the mounts were
  given, and one server answers to several names. A shared host proves dependence; a differing host
  proves nothing.

Recovery and history treat `.sameServer` as a mismatch: a different export on the server a transfer
used is a different tree, so what stands there now is not the copy that was recorded.

## Same server warns, and never blocks

`same-server` is a warning. The case that settles it is a NAS with two pools:

```
mercury.local:/mnt/tank/files-local     avail 5190 GB
mercury.local:/mnt/tank/files-photos    avail 5190 GB
mercury.local:/mnt/tank001/files-fast   avail  843 GB
```

`files-local` + `files-photos` is one pool wearing two names. `files-photos` + `files-fast` is very
likely two independent disk sets, and is exactly what a user with a scratch pool and a bulk pool
would pick. A block would refuse the second pairing, so the severity has to fit the weaker of the two
facts CardVault can actually establish.

What varies instead is the wording, which reports the observations rather than asserting a conclusion:

- always: both destinations are on *host*.
- when the export paths share a parent (`/mnt/tank`): they are exported from the same path.
- when the two mounts report identical free space: they report the same free space.
- when both hold: "One pool exported twice looks exactly like that, and CardVault cannot see the
  server's disks to tell it apart from two separate pools."

Both signals are corroboration only. `/mnt/<pool>/<dataset>` is a naming convention the server chose
and the client cannot verify, and matching free bytes is collision-prone in principle. Root is
excluded from the prefix comparison, because every share named at the top level shares it — which is
why an SMB share and an NFS export on one host can only ever match on capacity.

## A network Primary is a warning, not a block

The rule that a Primary must be local was keyed on the destination's position in the list, so it also
fired for a single network destination with no local copy anywhere — the NAS-only archive, which is
the configuration a user with no spare local disk actually wants. It has been replaced by two
warnings keyed on the mount:

- `network-destination`, once per share: keep it mounted until copying and verification finish.
- `network-only`, once for the transfer, when no destination is local: every copy is verified, and
  none of them is on a disk attached to this Mac.

The claim CardVault makes is that a copy was verified, and verification over a share is real. Every
copy is closed and reopened before it is read back, and both NFS and SMB answer an `open` by
revalidating with the server. Measured on NFS: the first read after a close runs at wire rate
(46–52 MB/s) while a second read of the same open file comes from the client cache at over 1.2 GB/s.

That measurement also rules out one tempting mechanism. `fcntl(F_NOCACHE)` is **not** a cache bypass
on NFS — a read with it set was served from cache at 1232 MB/s — so nothing here may reach for it to
force a server round-trip.

**Repeated verification needs no special handling.** The concern is a second read of a file inside the
cache's lifetime, which would confirm nothing about the bytes on the server: re-verification of an
already-verified file, or a resume pass that re-reads destination files to decide what to keep.
`LocalFileSystem.checksum` opens the file afresh on every call and holds no digest between them, so
every read — first or hundredth — begins with the `open` that forces revalidation. The invariant to
protect is that opening fresh, not any flag, is what reaches the server; it is asserted by
`checksumRereadsTheShare` in the opt-in suite below.

`verifiedNetworkOnly` is the user-visible half of this. A NAS-only run really is verified and the card
really is safe to eject, so the state carries the success tone — but it says where the copies went,
because a green checkmark cannot, and the absence of a local copy is not discovered until the share is
not mounted.

## Testing

Pure-function coverage is in `CardVaultTests/VolumeTopologyTests.swift` (`NetworkVolumeOriginTests`,
`NetworkPreflightTests`) and `CardVaultTests/CoreTests.swift`. None of it needs a mount.

`NetworkVolumeManualTests` is opt-in and runs against a real share:

```sh
CARDVAULT_NETWORK_VOLUME=/Volumes/files-photos \
CARDVAULT_NETWORK_VOLUME_2=/Volumes/files-local \
swift test --disable-sandbox --filter NetworkVolumeManualTests
```

`CARDVAULT_NETWORK_VOLUME_2` should be another share on the *same server*; without it, the
independence test skips. The suite creates and removes one directory per test inside the share and
writes nothing else. It has been run against both an NFS export and an SMB share, including a
complete NAS-only transfer through the shipping coordinator.

## Not covered

Two things #41 raised are deliberately still open, because neither is what a network Primary was
blocked on.

**A stalled hard mount.** macOS mounts NFS `hard` by default, so a read, write, or `stat` against a
share whose server has gone away blocks in the kernel indefinitely rather than failing the way a
yanked USB drive does. `Task.checkCancellation()` is checked *between* chunks, so a thread parked
inside one `read` cannot see a Stop until the mount unwedges, and there is no distinct "the share
stopped responding" state. What has been done is narrower: the existence checks behind Reveal Manifest
no longer run on the main actor, where a stalled mount turns into a beachball with no way out. Volume
identity is still resolved on the main actor, and blocks there exactly as the URL resource reads
already did.

**Bookmarks across unmount and remount.** Whether an app-scoped security bookmark to a share resolves
after the share is unmounted and remounted, and after a reboot, is untested — as is whether resolving
one *blocks* when the share is absent. `SecurityScopedBookmarkStore.resolve` renews stale bookmarks
already, and relaunch recovery can now confirm a remounted share by its origin rather than shrugging,
but the resolution behaviour itself needs the manual procedure that
`Docs/manual-removable-media-test.md` is the model for.
