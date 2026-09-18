-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (c) 2026 Romain Tisserand
--
-- Golden VCE/VDC/VPC register trace for a SuperGrafx title, out of MAME's `sgx` driver.
--
--   mame sgx -cart game.sgx -video none -sound none -nothrottle \
--            -seconds_to_run 30 -skip_gameinfo \
--            -plugins -autoboot_script sgx_vgold.lua
--
-- WHY MAME AND NOT BEETLE: the existing golden tooling (golden/run_vgold.sh) uses
-- beetle-pce-fast, and Mednafen's pce_fast module has NO SuperGrafx support at all -- it
-- would run a .sgx as a plain PC Engine and produce a reference that means nothing. MAME's
-- sgx driver is a real SuperGrafx, and its LUA debugger can tap writes without rebuilding
-- anything.
--
-- Output (PCE_VGOLD_OUT, default sgx_vgold.log), one line per access:
--
--   <frame> W VCE  <addr> <data>      VCE  $1FE400-$1FE407  palette + video control
--   <frame> W VDC0 <addr> <data>      VDC0 $1FE000-$1FE007
--   <frame> W VPC  <addr> <data>      VPC  $1FE008-$1FE00F  (SuperGrafx only)
--   <frame> W VDC1 <addr> <data>      VDC1 $1FE010-$1FE017  (SuperGrafx only)
--   <frame> R <blk> <addr>            reads, which is how IRQs get acknowledged
--
-- Frame numbers are mandatory, not decoration: without them a late write reads like an
-- init write, which has already caused one wrong root-cause call on this project.
--
-- The PC Engine I/O page is physical bank $FF, so the hardware at logical $0000 lives at
-- $1FE000 in the CPU's 21-bit physical space.

local OUT = os.getenv("PCE_VGOLD_OUT") or "sgx_vgold.log"
local VERBOSE_READS = (os.getenv("PCE_VGOLD_READS") or "1") ~= "0"

local f = assert(io.open(OUT, "w"))
local screen = manager.machine.screens[":screen"]
local cpu = manager.machine.devices[":maincpu"]
local space = cpu.spaces["program"]

local counts = { VDC0 = 0, VPC = 0, VDC1 = 0, VCE = 0 }

local function block(addr)
    if addr >= 0x1FE400 and addr <= 0x1FE407 then return "VCE"  end
    if addr >= 0x1FE010 and addr <= 0x1FE017 then return "VDC1" end
    if addr >= 0x1FE008 and addr <= 0x1FE00F then return "VPC"  end
    if addr >= 0x1FE000 and addr <= 0x1FE007 then return "VDC0" end
    return nil
end

local function frame()
    return screen ~= nil and screen:frame_number() or 0
end

space:install_write_tap(0x1FE000, 0x1FE7FF, "sgx_vgold_w", function(offset, data, mask)
    local b = block(offset)
    if b then
        counts[b] = counts[b] + 1
        f:write(string.format("%d W %s %06X %02X\n", frame(), b, offset, data & 0xFF))
    end
    return data
end)

if VERBOSE_READS then
    space:install_read_tap(0x1FE000, 0x1FE7FF, "sgx_vgold_r", function(offset, data, mask)
        local b = block(offset)
        if b then
            f:write(string.format("%d R %s %06X\n", frame(), b, offset))
        end
        return data
    end)
end

emu.register_stop(function()
    f:write(string.format("# END frame=%d VDC0=%d VPC=%d VDC1=%d VCE=%d\n",
                          frame(), counts.VDC0, counts.VPC, counts.VDC1, counts.VCE))
    f:close()
end)

emu.print_info(string.format("sgx_vgold: tapping $1FE000-$1FE7FF -> %s", OUT))
