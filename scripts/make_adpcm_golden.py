#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Romain Tisserand

"""Regenerate the ADPCM golden fixtures from YOUR OWN copy of the disc.

    scripts/make_adpcm_golden.py "Akumajou Dracula X - Chi no Rondo.chd"
    scripts/make_adpcm_golden.py game.bin            # already-extracted 2352-byte image

The ADPCM testbenches (sim/cd/tb_adpcm_dma.vhd, sim/cd/tb_adpcm_golden.vhd) compare the
core against a real game's real ADPCM data. That data is Konami's, so it is NOT
redistributed in this repository -- only the sector NUMBERS it lives at, which are
metadata. Point this script at your own dump and it rebuilds the fixtures locally.

WHAT EACH FIXTURE IS, and why only two of the four need the disc at all:

  adpcm_rondo_dma1/sectors.hex     user data of LBA 4127..4158, the game's first
                                   DMA-from-CD ADPCM load (32 sectors, 65536 bytes)
  adpcm_rondo_dma1/dma_writes.hex  DERIVED from sectors.hex: beetle's 65536 ADPCM RAM
                                   writes are "addr value" with addr strictly sequential
                                   0x0000..0xFFFF and value == the sector byte. Verified
                                   65536/65536 exact, so it needs no separate capture.
  adpcm_rondo_play8/ram.hex        the 64 KB ADPCM RAM image at the start of PLAY #8.
                                   NOT one contiguous read -- it is what several earlier
                                   game loads left behind -- so it is rebuilt from the
                                   per-2KB-block LBA map below, every block of which was
                                   located in the disc image and verified byte-exact.
  adpcm_rondo_play8/nib.hex        DERIVED from ram.hex: the 1448 nibbles fed to the OKI
                                   decoder = 724 bytes from 0x8df8, high nibble first.
                                   Verified 1448/1448 exact.

regs.txt and the per-case README files are behavioural notes, not disc content, and stay
in the repository.

The MD5s below are of the fixtures as originally captured from an instrumented
beetle-pce-fast run. A mismatch means your dump differs from the one used then (a
different release or a bad rip), and the testbenches would be comparing against something
other than what their expectations were written for -- so it is reported loudly.
"""

import hashlib
import os
import subprocess
import sys
import tempfile

SECTOR_SIZE = 2352      # MODE1/2352, as chdman extracts it
USER_OFFSET = 16        # sync (12) + header (4)
USER_SIZE = 2048

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, os.pardir, "sim", "cd", "golden")

# The first DMA-from-CD ADPCM load: 32 consecutive sectors.
DMA1_LBA0, DMA1_COUNT = 4127, 32

# PLAY #8's RAM image, one LBA per 2048-byte block of ADPCM RAM, in RAM order.
# Discontiguous on purpose -- see the module docstring.
PLAY8_RAM_LBAS = [
    4515, 4516, 4517,
    4622, 4623, 4624,
    8041, 8042, 8043, 8044, 8045, 8046, 8047, 8048, 8049,
    8050, 8051, 8052, 8053, 8054, 8055, 8056, 8057,
    7906, 7907,
    8060, 8061, 8062, 8063, 8064, 8065, 8066,
]

# PLAY #8 reads 724 bytes from 0x8df8 ($1808/$1809 <- f8 8d in regs.txt).
PLAY8_NIB_START, PLAY8_NIB_BYTES = 0x8df8, 724

EXPECTED_MD5 = {
    "adpcm_rondo_dma1/sectors.hex":    "2019b527e174d48c17747dbc3b1a4d59",
    "adpcm_rondo_dma1/dma_writes.hex": "cdc6356d5454969425bbe51ba756cbc7",
    "adpcm_rondo_play8/ram.hex":       "904c7e38e8757581d77cabbcbfaed20a",
    "adpcm_rondo_play8/nib.hex":       "b2f8bcdaea53e8faf5b459079242f795",
}


def extract_chd(chd, workdir):
    """chdman extractcd -> a 2352-byte/sector .bin, same layout the LBA map assumes."""
    binpath = os.path.join(workdir, "disc.bin")
    cue = os.path.join(workdir, "disc.cue")
    print(f"extracting {os.path.basename(chd)} (this takes a minute)...")
    try:
        subprocess.run(
            ["chdman", "extractcd", "-i", chd, "-o", cue, "-ob", binpath, "-f"],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    except FileNotFoundError:
        sys.exit("error: chdman not found. Install MAME tools, or pass an extracted .bin.")
    except subprocess.CalledProcessError as e:
        sys.exit(f"error: chdman failed:\n{e.stderr.decode(errors='replace')}")
    return binpath


def read_user(fh, lba, count=1):
    """The user-data payload of `count` sectors starting at `lba`."""
    out = bytearray()
    for k in range(count):
        fh.seek((lba + k) * SECTOR_SIZE + USER_OFFSET)
        chunk = fh.read(USER_SIZE)
        if len(chunk) != USER_SIZE:
            sys.exit(f"error: disc image too short at LBA {lba + k} -- wrong image?")
        out += chunk
    return bytes(out)


def write_lines(relpath, lines):
    path = os.path.normpath(os.path.join(GOLDEN, relpath))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    digest = hashlib.md5(open(path, "rb").read()).hexdigest()
    want = EXPECTED_MD5.get(relpath)
    state = "ok" if digest == want else f"MISMATCH (expected {want})"
    print(f"  {relpath:38} {len(lines):>6} lines  md5 {digest}  {state}")
    return digest == want


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[0] + "\n\n"
                 "usage: make_adpcm_golden.py <game.chd | game.bin>")
    src = sys.argv[1]
    if not os.path.isfile(src):
        sys.exit(f"error: no such file: {src}")

    tmp = None
    try:
        if src.lower().endswith(".chd"):
            tmp = tempfile.mkdtemp(prefix="adpcm_golden_")
            binpath = extract_chd(src, tmp)
        else:
            binpath = src

        with open(binpath, "rb") as fh:
            print("regenerating fixtures:")

            sectors = read_user(fh, DMA1_LBA0, DMA1_COUNT)
            allok = write_lines("adpcm_rondo_dma1/sectors.hex",
                                [f"{b:02x}" for b in sectors])

            # Derived, not captured: addresses are sequential and values are the bytes.
            allok &= write_lines("adpcm_rondo_dma1/dma_writes.hex",
                                 [f"{i:04x} {b:02x}" for i, b in enumerate(sectors)])

            ram = b"".join(read_user(fh, lba) for lba in PLAY8_RAM_LBAS)
            allok &= write_lines("adpcm_rondo_play8/ram.hex",
                                 [f"{b:02x}" for b in ram])

            # Derived: 724 bytes from 0x8df8, high nibble first.
            nibs = []
            for b in ram[PLAY8_NIB_START:PLAY8_NIB_START + PLAY8_NIB_BYTES]:
                nibs.append(f"{b >> 4:x}")
                nibs.append(f"{b & 0xf:x}")
            allok &= write_lines("adpcm_rondo_play8/nib.hex", nibs)
    finally:
        if tmp:
            import shutil
            shutil.rmtree(tmp, ignore_errors=True)

    if allok:
        print("\nAll four fixtures match the original capture. "
              "sim/cd/run_adpcm_dma.sh and run_adpcm_golden.sh will now run.")
    else:
        print("\nWARNING: at least one fixture does not match the original capture.\n"
              "Your disc image is probably a different release or a bad rip. The\n"
              "testbenches will run but their expected values were written against the\n"
              "capture above, so failures may not mean the core is wrong.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
