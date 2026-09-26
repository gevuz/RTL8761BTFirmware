// SPDX-License-Identifier: GPL-2.0-or-later
//
// Parser for Realtek "epatch" v1 firmware files ("Realtech" signature), following
// rtlbt_parse_firmware in Linux drivers/bluetooth/btrtl.c. Plain C: it is built into both
// the kext and the rtlbtctl test tool.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t fw_version;   // version stored in the file (the chip reports it once loaded)
    uint16_t num_patches;
    int project_id;        // 14 = RTL8761B
    uint16_t patch_len;    // size of the selected patch (before the config is appended)
    uint32_t patch_off;
} rtl_epatch_info;

// Upper bound of what rtl_epatch_build can produce (to size the output buffer).
size_t rtl_epatch_max_payload(size_t fw_len, size_t cfg_len);

// Builds the payload sent to the chip: the patch for its ROM version, with the firmware version
// in the last 4 bytes, followed by the config. Returns 0, or -1 with *err pointing to a static message.
int rtl_epatch_build(const uint8_t *fw, size_t fw_len, const uint8_t *cfg, size_t cfg_len, uint8_t rom_version,
                     uint8_t *out, size_t out_cap, size_t *out_len, rtl_epatch_info *info, const char **err);

#ifdef __cplusplus
}
#endif
