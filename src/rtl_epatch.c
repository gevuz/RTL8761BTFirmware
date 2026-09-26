// SPDX-License-Identifier: GPL-2.0-or-later
//
// See rtl_epatch.h.

#include "rtl_epatch.h"

#include <string.h>

#define HEADER_LEN 14  // "Realtech" + fw_version (4) + num_patches (2)
#define PROJECT_ID_8761B 14

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

size_t rtl_epatch_max_payload(size_t fw_len, size_t cfg_len) { return fw_len + cfg_len; }

int rtl_epatch_build(const uint8_t *fw, size_t fw_len, const uint8_t *cfg, size_t cfg_len, uint8_t rom_version,
                     uint8_t *out, size_t out_cap, size_t *out_len, rtl_epatch_info *info, const char **err) {
    static const uint8_t ext_sig[] = {0x51, 0x04, 0xfd, 0x77};
    size_t min_size = HEADER_LEN + sizeof(ext_sig) + 3;

    if (fw_len < min_size || memcmp(fw, "Realtech", 8) != 0) {
        *err = (fw_len >= 8 && memcmp(fw, "RTBTCore", 8) == 0) ? "v2 firmware (RTBTCore) is not supported"
                                                               : "'Realtech' signature not found";
        return -1;
    }
    if (memcmp(fw + fw_len - sizeof(ext_sig), ext_sig, sizeof(ext_sig)) != 0) {
        *err = "extension section signature mismatch";
        return -1;
    }

    // Walk the instructions at the end of the file backwards until the "project ID" is found.
    int project_id = -1;
    const uint8_t *p = fw + fw_len - sizeof(ext_sig);
    while (p >= fw + HEADER_LEN + 3) {
        uint8_t opcode = *--p, length = *--p, data = *--p;
        if (opcode == 0xff)
            break;
        if (length == 0) {
            *err = "instruction with length 0";
            return -1;
        }
        if (opcode == 0 && length == 1) {
            project_id = data;
            break;
        }
        p -= length;
    }
    // 8761 family project IDs in btrtl.c: 3 (8761A), 14 (8761B), 51 (8761C)
    if (project_id != PROJECT_ID_8761B) {
        *err = "project ID is not 14 (not an RTL8761B firmware)";
        return -1;
    }

    uint16_t num_patches = le16(fw + 12);
    min_size += 8 * (size_t)num_patches;
    if (fw_len < min_size) {
        *err = "file is smaller than its patch table";
        return -1;
    }

    const uint8_t *chip_ids = fw + HEADER_LEN;
    const uint8_t *lengths = chip_ids + 2 * num_patches;
    const uint8_t *offsets = lengths + 2 * num_patches;
    uint16_t patch_len = 0;
    uint32_t patch_off = 0;
    for (uint16_t i = 0; i < num_patches; i++) {
        if (le16(chip_ids + 2 * i) == rom_version + 1) {
            patch_len = le16(lengths + 2 * i);
            patch_off = le32(offsets + 4 * i);
            break;
        }
    }
    if (!patch_off) {
        *err = "no patch for this chip's ROM version";
        return -1;
    }
    if (patch_len < 4 || patch_off > fw_len || patch_len > fw_len - patch_off) {
        *err = "patch is out of the file bounds";
        return -1;
    }
    if ((size_t)patch_len + cfg_len > out_cap) {
        *err = "output buffer too small";
        return -1;
    }

    memcpy(out, fw + patch_off, patch_len - 4);
    memcpy(out + patch_len - 4, fw + 8, 4);  // fw_version, as stored in the file (little-endian)
    if (cfg_len)
        memcpy(out + patch_len, cfg, cfg_len);
    *out_len = (size_t)patch_len + cfg_len;

    if (info) {
        info->fw_version = le32(fw + 8);
        info->num_patches = num_patches;
        info->project_id = project_id;
        info->patch_len = patch_len;
        info->patch_off = patch_off;
    }
    return 0;
}
