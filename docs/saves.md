# Saved games and the profile

The runtime gives the title one storage device, content packages to save into,
a writable filesystem inside them, and a profile that keeps its settings. The
title saves and loads with its own code; nothing here knows MW2's save format.

Everything is kept under `saves/` in the current directory. A player's start
changes to the executable's folder first, so there it is beside the executable
and `game/`. It is never inside the game root, which is the disc and
read-only.

## How the title saves

The save system is two steps:

1. **Mount a package as a drive.** The memcard code fills an `XCONTENT_DATA`
   (the device, content type 1 for a saved game, a display name and the name on
   disk, `savegame.svg`) and calls `XContentCreate` with a create disposition
   in the low nibble of its flags. On the console this opens an STFS container,
   a signed archive, as the drive `save0:`.
2. **Write an ordinary file into it.** It opens `save0:\savegame.svg` with
   `CreateFile` (`GENERIC_WRITE` and `CREATE_NEW` to save, `GENERIC_READ` and
   `OPEN_EXISTING` to load) and reads or writes it like any other file.

The title never looks inside the container, so a package here is a
**directory**, `saves/<name on disk>/`, and mounting it is an entry in the file
layer's device table. The save is `saves/savegame.svg/savegame.svg`.

## Content calls (`kernel/content.cpp`)

| call | behaviour |
|---|---|
| `XamContentGetDeviceState` | device 1 (`kernel::kSaveDeviceId`) is connected; any other is not |
| `XamContentGetDeviceData` | one hard disk, 16 GB with 8 GB free: the title compares the free space with what it is about to write and refuses to save if it does not fit |
| `XamContentCreateEx` | honours the disposition (create new, create always, open existing, open always, truncate), reports whether the package was new or existing, and mounts it |
| `XamContentClose` | unmounts |
| `XamContentDelete` | removes the directory, and the `.bak` beside it |

**Create-always and truncate empty the package first.** That is what the
disposition means, and the title relies on it: it then creates its file with
`CREATE_NEW`, so a file left from the previous save would collide and the save
would fail.

The package is not emptied in place, though. It is renamed to `<name>.bak` and
a fresh one made, so the previous save still exists whole while the title is
part-way through writing the new one — a kill between the two used to leave the
player with neither (see [Surviving an interrupted
write](#surviving-an-interrupted-write)). Only one generation is kept: the next
save replaces it. Nothing reads it back automatically, because the file inside
is MW2's own format and this runtime cannot tell a good one from a truncated
one; recovering it means renaming the directory by hand. `XamContentDelete`
removes it too, so deleting a save does not leave the old one behind, and
`kernel::MovePlayerData` carries it along when a package is renamed to another
player's number.

Package names are sanitised to letters, digits, `_`, `-` and `.`, since they
become host paths.

## Files inside a package (`kernel/files.cpp`)

The device prefix of a guest path is looked up in the mount table. A path under
a mount resolves in the package directory, where `NtCreateFile` honours its
create disposition, `NtWriteFile` writes, and `NtSetInformationFile` seeks,
truncates and marks a file for deletion. Every other path resolves under the
game root and is read-only; truncation is gated on the path being writable, not
on what the disposition asks for, so opening a disc file with
`FILE_OVERWRITE_IF` cannot empty it. See [runtime.md](runtime.md#files).

## The device selector

`XamShowDeviceSelectorUI` writes device 1 as the choice, completes the
overlapped block and returns `ERROR_IO_PENDING`. The title's caller tests for
exactly that return and then polls `XGetOverlappedResult`; any other return,
success included, takes its "the player refused" path.

The memcard code keeps the device each controller saves to in a table of one
word per controller (`T_DATA_DeviceTable` in `title.h`); zero means nobody has
chosen, which is what puts the prompt in front of the player. The console
remembers the choice in the profile, so it is made once ever. Here the table
starts empty at every launch, so the runtime hooks `Memcard_InitializeSystem`
and, when it returns, fills every empty entry with device 1.
`PES17_NO_AUTO_SAVE_DEVICE=1` leaves the table alone, and the prompt then works
as on the console. The table's address is known for the campaign only; in the
multiplayer build the seed does nothing.

## The profile (`kernel/profile.cpp`)

MW2 keeps its own settings (controls, video, and what the player sets on the
first-boot calibration screens) in the two 1000-byte blobs the console reserves
for a title in the player's profile, `XPROFILE_TITLE_SPECIFIC1` and 2. It
writes them with `XamUserWriteProfileSettings` and reads them back at start-up,
with six system settings, through `XamUserReadProfileSettings`.

The runtime stores every setting the title writes in `saves/profile.bin` and
hands it back unchanged. That file is the first controller's player's; a
profile signed in at another controller ([gameplay.md](gameplay.md#signing-in))
has `profile_<id>.bin`. A setting is an id, a source and its bytes; nothing
interprets them. Settings never written (the six system settings among them)
are answered as unset, which is what an offline profile with nothing
configured looks like. An empty profile makes every launch a first boot, with
the calibration screens and defaults.

`XUSER_PROFILE_SETTING` is 40 bytes, as the title's reader walks it:

| offset | field |
|---|---|
| +0 | source; **zero means "not set"**, and the title checks it before anything else |
| +8 | user index |
| +16 | setting id; its top nibble is the type: 6 is a byte blob, anything else fits in the eight bytes at +32 |
| +32 | the value, or for a blob its size |
| +36 | for a blob, the address of its bytes |

A read returns a header (count, pointer to the entries) followed by the entries,
with blobs placed after the entry array and pointed to by their entries, so the
buffer size a caller needs depends on what is stored. A call with too small a
buffer gets the required size and `ERROR_INSUFFICIENT_BUFFER`, and callers size
their buffer with a first call.

`profile.bin` is `MW2PROF1`, a count, then id, source, length and bytes for each
setting, in host byte order for the header fields and the guest's byte order
for the values.

A profile that cannot be parsed is **not** treated as an empty one. An empty
profile makes the title run its first boot again and lose every setting, so a
read that fails falls back to `profile.bin.bak` and, if that parses, writes it
back under the real name. Only when neither is readable does it start fresh, and
it says so in the log.

## Surviving an interrupted write

Nothing here can count on reaching its next line. Android's low memory killer
takes the process away by design, a lost Vulkan device exits it outright
(`gpu/vulkan/renderer.cpp`, `OnDeviceLost`), and the manifest sets
`allowBackup="false"`, so a save that goes is gone. Everything this runtime
writes is small, written rarely and irreplaceable, which makes the trade an easy
one: pay a sync on every save rather than lose one.

`kernel::WriteFileAtomically` (`kernel/durable.h`) is what the profile goes
through, and it does two things stdio does not:

* **It never opens the target for truncation.** The bytes go to `<path>.tmp`,
  which is renamed over the target once it is whole. `rename` is atomic, so at
  every instant one name or the other holds a complete file; the previous
  contents move to `<path>.bak` rather than being overwritten.
* **It waits for storage.** `fflush` only moves bytes from the process's buffer
  into the kernel's page cache, which is written back whenever the kernel
  chooses — a reset in between loses them. `kernel::SyncStream` follows the
  flush with `fsync` (`_commit` on Windows), and on POSIX the directory is
  synced too, since a rename is only as durable as the directory entry it made.

The same sync runs for the title's own writes: `NtFlushBuffersFile` is a real
`fsync` rather than a flush, and closing a writable file inside a mounted
package syncs it. That is paid on saves and nothing else, because the disc is
read-only and a write anywhere outside a package is discarded before it reaches
a handle.

`tests/durable_test.cpp` asserts these properties — that a replacement leaves
the previous contents whole, that a successful write leaves no `.tmp`, that one
left by a dead run is not mistaken for the target, and that sizes round-trip
across block boundaries. It depends on neither the guest nor the recompiled
image, so `ctest` runs it on a tree with no disc, no game files and no GPU.

## Driving the first boot headlessly

The calibration screens accept nothing until their slider has moved, so a
scripted run has to push a stick. `PES17_INPUT_SCRIPT` (diagnostic builds) takes
stick directions with a hold time; the whole first boot (brightness,
horizontal margin, vertical margin, then the content notice) is:

    PES17_INPUT_SCRIPT="15:start,20:lx-:1,24:a,28:lx-:1,32:a,36:lx-:1,40:a,46:a"

## What the launcher changes

The launcher's PROFILES screen (`launcher/profile.cpp`) edits two of these files
itself, without the title; each is copied to `<name>.backup` before its first
change.

**The multiplayer's stats.** A player's rank, unlocks and classes are one
buffer the title lays out by `mp/playerdata.def`. The online service keeps it
as `saves/online/user/<xuid>/mpdata`: a CRC-32 of the rest, high byte first,
then the buffer, 8188 bytes whose values are low byte first and which opens
with the layout's version (155) and checksum. The offline profile's is the
content package `saves/mpdata_<xuid>/`, the same with four bytes before and
one after. A file with another version or checksum is left alone. A profile
([gameplay.md](gameplay.md#signing-in)) has both, named by its number; the
screen shows it once, with the rank of each, and a change is made to both.
Stats under a number no profile has are listed as nobody's.

Where a value is in the buffer is the title's knowledge, in a signed fastfile,
as are the challenges' tiers and the ranks. `tools/playerdata_layout.py` reads
all three from a running multiplayer's memory and writes
`launcher/playerdata_layout.h`, which is committed. From it:

| entry | change |
|---|---|
| MAX RANK | `experience` to the last rank's end |
| PRESTIGE | `prestige`, one more each time, 0 after 10 |
| UNLOCK EVERYTHING | each challenge's `challengeState` to one past its last tier and its `challengeProgress` to that tier's target; every bit of `titleUnlocked`, `iconUnlocked` and `killstreakUnlocked` |

The title's own console commands are the check on a change: `dumpPlayerData`
prints the whole buffer by name as the title reads it, `setPlayerData` and
`getPlayerData` take a path into it, `uploadStats` writes the file
(`PES17_CONSOLE`, `PES17_ENGINE_LOG=1`).

**The campaign's progress** is in the profile, in two of the title's
settings. Each is `SEMV`, two words, then numbered fields: a number, a type
and a value -- one byte (types 1 and 2), 32 bits (4 and 5), or a string (6) as
two 16-bit words (where it goes in the title's string area, and its room) and
its characters up to a zero.

- `0x63E83FFE`, the campaign's own: field 6 is `highestMission`, field 7
  `missionspecops`, fields `0x22` and `0x23` the highest difficulty each
  campaign and Special Ops mission was finished at, a digit per mission.
- `0x63E83FFF`, which both executables read: field `0x0E` is
  `percentcompleteso`, which despite its name is the number of Special Ops
  stars, and what the menus open the mission groups by.

The names are the title's, from its table of profile fields at `0x82011330`.

| entry | change |
|---|---|
| UNLOCK ALL MISSIONS | `highestMission` to 20 |
| ALL SPEC OPS STARS | the first 23 digits of field `0x23` to `4`, veteran, which is three stars, and the star count to 69 |

