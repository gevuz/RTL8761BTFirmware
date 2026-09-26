// SPDX-License-Identifier: GPL-2.0-or-later
//
// RTL8761BTFirmware: uploads the Realtek RTL8761BU/BUV firmware at boot, then releases the
// dongle so bluetoothd (patched by BlueToolFixup) can take it over.
// The upload protocol follows Linux drivers/bluetooth/btrtl.c.

#include "RTL8761BTFirmware.hpp"

#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IOLib.h>
#include <kern/clock.h>
#include <pexpert/pexpert.h>

#include "firmware_blob.h"
#include "rtl_epatch.h"

#define LOG(fmt, ...) IOLog("RTL8761BTFirmware: " fmt "\n", ##__VA_ARGS__)

OSDefineMetaClassAndStructors(RTL8761BTFirmware, IOService)

// Values reported by the chip before any firmware is loaded ("8761BU" entry in btrtl.c)
static const uint16_t kROMLmpSubver = 0x8761;
static const uint16_t kHciRev8761BU = 0x000b;
static const uint8_t kHciVer8761BU = 0x0a;
static const uint16_t kManufacturerRealtek = 0x005d;

static const uint16_t kOpReadLocalVersion = 0x1001;
static const uint16_t kOpRtlDownload = 0xfc20;
static const uint16_t kOpRtlReadRomVersion = 0xfc6d;
static const size_t kFragLen = 252;
static const uint32_t kCommandTimeoutMs = 5000;
static const uint32_t kMaxEvent = 2 + 255;
static const int kMaxIgnoredEvents = 32;  // unrelated events tolerated before giving up on a command

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

bool RTL8761BTFirmware::start(IOService *provider) {
    char flag[8];
    if (PE_parse_boot_argn("-rtlbtoff", flag, sizeof(flag))) {
        LOG("disabled by the -rtlbtoff boot-arg");
        return false;
    }
    auto dev = OSDynamicCast(IOUSBHostDevice, provider);
    if (!dev || !IOService::start(provider))
        return false;

    ioLock = IOLockAlloc();
    IOReturn ret = ioLock ? openDongle(dev) : kIOReturnNoMemory;
    if (ret == kIOReturnSuccess)
        ret = uploadIfNeeded();
    closeDongle();
    if (ioLock) {
        IOLockFree(ioLock);
        ioLock = nullptr;
    }
    if (ret != kIOReturnSuccess)
        LOG("failed (0x%x); the dongle is left without firmware", ret);

    // Do not stay attached: bluetoothd opens the dongle on its own later.
    return false;
}

#pragma mark - Open and close

IOReturn RTL8761BTFirmware::openDongle(IOUSBHostDevice *dev) {
    device = dev;
    device->retain();
    if (!device->open(this)) {
        device->release();
        device = nullptr;
        LOG("could not open the device (already opened by another client?)");
        return kIOReturnExclusiveAccess;
    }

    // If unconfigured, select configuration 1. matchInterfaces=false keeps other drivers off the interfaces.
    if (!device->getConfigurationDescriptor()) {
        IOReturn ret = device->setConfiguration(1, false);
        if (ret != kIOReturnSuccess) {
            LOG("could not configure the device (0x%x)", ret);
            return ret;
        }
    }

    // Interface 0 may take a moment to show up after configuring.
    for (int attempt = 0; attempt < 40 && !interface; attempt++) {
        OSIterator *it = device->getChildIterator(gIOServicePlane);
        if (it) {
            while (OSObject *obj = it->getNextObject()) {
                auto candidate = OSDynamicCast(IOUSBHostInterface, obj);
                if (candidate && candidate->getInterfaceDescriptor()->bInterfaceNumber == 0) {
                    interface = candidate;
                    interface->retain();
                    break;
                }
            }
            it->release();
        }
        if (!interface)
            IOSleep(50);
    }
    if (!interface) {
        LOG("interface 0 did not show up");
        return kIOReturnNotFound;
    }
    if (!interface->open(this)) {
        interface->release();
        interface = nullptr;
        LOG("could not open interface 0");
        return kIOReturnExclusiveAccess;
    }

    // HCI event endpoint: the interrupt IN endpoint of interface 0.
    const StandardUSB::ConfigurationDescriptor *config = interface->getConfigurationDescriptor();
    const StandardUSB::InterfaceDescriptor *intfDesc = interface->getInterfaceDescriptor();
    const StandardUSB::EndpointDescriptor *ep = nullptr;
    while ((ep = StandardUSB::getNextEndpointDescriptor(config, intfDesc, reinterpret_cast<const StandardUSB::Descriptor *>(ep)))) {
        if (StandardUSB::getEndpointType(ep) == kIOUSBEndpointTypeInterrupt &&
            StandardUSB::getEndpointDirection(ep) == kIOUSBEndpointDirectionIn)
            break;
    }
    if (!ep) {
        LOG("event endpoint (interrupt IN) not found");
        return kIOReturnNotFound;
    }
    eventPacketSize = USBToHost16(ep->wMaxPacketSize) & 0x7ff;
    eventPipe = interface->copyPipe(StandardUSB::getEndpointAddress(ep));
    eventBuffer = interface->createIOBuffer(kIODirectionIn, eventPacketSize);
    if (!eventPipe || !eventBuffer) {
        LOG("could not set up the event endpoint");
        return kIOReturnNoResources;
    }
    return kIOReturnSuccess;
}

void RTL8761BTFirmware::closeDongle() {
    if (eventPipe) {
        eventPipe->abort(IOUSBHostIOSource::kAbortSynchronous);
        eventPipe->release();
        eventPipe = nullptr;
    }
    if (eventBuffer) {
        eventBuffer->release();
        eventBuffer = nullptr;
    }
    if (interface) {
        interface->close(this);
        interface->release();
        interface = nullptr;
    }
    if (device) {
        device->close(this);
        device->release();
        device = nullptr;
    }
}

#pragma mark - HCI

IOReturn RTL8761BTFirmware::sendCommandPacket(uint16_t opcode, const void *params, uint8_t plen) {
    uint8_t pkt[3 + 255];
    pkt[0] = opcode & 0xff;
    pkt[1] = opcode >> 8;
    pkt[2] = plen;
    if (plen)
        memcpy(pkt + 3, params, plen);
    // HCI command over USB: class request on the default control endpoint (Bluetooth Core, USB transport)
    StandardUSB::DeviceRequest req = {.bmRequestType = 0x20, .bRequest = 0, .wValue = 0, .wIndex = 0, .wLength = (uint16_t)(3 + plen)};
    uint32_t sent = 0;
    return device->deviceRequest(this, req, pkt, sent, kCommandTimeoutMs);
}

namespace {
struct ReadWaiter {
    IOLock *lock;
    bool done;
    IOReturn status;
    uint32_t bytes;
};
}  // namespace

void RTL8761BTFirmware::eventReadCompleted(void *owner, void *parameter, IOReturn status, uint32_t bytesTransferred) {
    auto w = static_cast<ReadWaiter *>(parameter);
    IOLockLock(w->lock);
    w->status = status;
    w->bytes = bytesTransferred;
    w->done = true;
    IOLockWakeup(w->lock, w, false);
    IOLockUnlock(w->lock);
}

// Reads one packet from the event endpoint. Interrupt pipes take no timeout, so we add our own.
IOReturn RTL8761BTFirmware::readEventPacket(uint8_t *out, uint32_t *len, uint32_t timeoutMs) {
    ReadWaiter w = {ioLock, false, kIOReturnError, 0};
    IOUSBHostCompletion completion = {this, eventReadCompleted, &w};
    IOReturn ret = eventPipe->io(eventBuffer, eventPacketSize, &completion, 0);
    if (ret != kIOReturnSuccess)
        return ret;

    uint64_t deadline;
    clock_interval_to_deadline(timeoutMs, kMillisecondScale, &deadline);
    IOLockLock(ioLock);
    while (!w.done && IOLockSleepDeadline(ioLock, &w, deadline, THREAD_UNINT) != THREAD_TIMED_OUT) {
    }
    bool timedOut = !w.done;
    IOLockUnlock(ioLock);
    if (timedOut) {
        // Aborting completes the pending read; wait for the completion before the waiter goes out of scope.
        eventPipe->abort(IOUSBHostIOSource::kAbortSynchronous);
        IOLockLock(ioLock);
        while (!w.done)
            IOLockSleep(ioLock, &w, THREAD_UNINT);
        IOLockUnlock(ioLock);
        return kIOReturnTimeout;
    }
    if (w.status != kIOReturnSuccess)
        return w.status;
    memcpy(out, eventBuffer->getBytesNoCopy(), w.bytes);
    *len = w.bytes;
    return kIOReturnSuccess;
}

// An HCI event may span several packets: read until we have the 2-byte header plus its parameters.
IOReturn RTL8761BTFirmware::readEvent(uint8_t *out, uint32_t cap, uint32_t *len, uint32_t timeoutMs) {
    uint32_t have = 0;
    while (have < 2 || have < 2u + out[1]) {
        if (have + eventPacketSize > cap)
            return kIOReturnOverrun;
        uint32_t got = 0;
        IOReturn ret = readEventPacket(out + have, &got, timeoutMs);
        if (ret != kIOReturnSuccess)
            return ret;
        have += got;
    }
    *len = have;
    return kIOReturnSuccess;
}

// Sends a command and returns the Command Complete parameters (starting at the status byte).
IOReturn RTL8761BTFirmware::hciCommand(uint16_t opcode, const void *params, uint8_t plen, uint8_t *reply, uint32_t replyCap,
                                       uint32_t *replyLen) {
    IOReturn ret = sendCommandPacket(opcode, params, plen);
    if (ret != kIOReturnSuccess) {
        LOG("could not send command 0x%04x (0x%x)", opcode, ret);
        return ret;
    }
    uint8_t evt[kMaxEvent + 64];
    for (int ignored = 0; ignored <= kMaxIgnoredEvents; ignored++) {
        uint32_t len = 0;
        ret = readEvent(evt, sizeof(evt), &len, kCommandTimeoutMs);
        if (ret != kIOReturnSuccess) {
            LOG("no reply to command 0x%04x (0x%x)", opcode, ret);
            return ret;
        }
        if (evt[0] == 0x0e && len >= 6 && le16(evt + 3) == opcode) {
            uint32_t n = len - 5;
            if (n > replyCap)
                return kIOReturnOverrun;
            memcpy(reply, evt + 5, n);
            *replyLen = n;
            return kIOReturnSuccess;
        }
        if (evt[0] == 0x0f && len >= 6 && le16(evt + 4) == opcode) {
            LOG("command 0x%04x rejected (Command Status 0x%02x)", opcode, evt[2]);
            return kIOReturnError;
        }
    }
    LOG("command 0x%04x: too many unrelated events", opcode);
    return kIOReturnIOError;
}

IOReturn RTL8761BTFirmware::readLocalVersion(LocalVersion *v) {
    uint8_t r[16];
    uint32_t n = 0;
    IOReturn ret = hciCommand(kOpReadLocalVersion, nullptr, 0, r, sizeof(r), &n);
    if (ret != kIOReturnSuccess)
        return ret;
    if (n < 9 || r[0] != 0)
        return kIOReturnError;
    *v = {.hciVer = r[1], .lmpVer = r[4], .hciRev = le16(r + 2), .manufacturer = le16(r + 5), .lmpSubver = le16(r + 7)};
    LOG("version: hci_ver=0x%02x hci_rev=0x%04x lmp_ver=0x%02x manufacturer=0x%04x lmp_subver=0x%04x", v->hciVer, v->hciRev, v->lmpVer,
        v->manufacturer, v->lmpSubver);
    return kIOReturnSuccess;
}

IOReturn RTL8761BTFirmware::readRomVersion(uint8_t *version) {
    uint8_t r[8];
    uint32_t n = 0;
    IOReturn ret = hciCommand(kOpRtlReadRomVersion, nullptr, 0, r, sizeof(r), &n);
    if (ret != kIOReturnSuccess)
        return ret;
    if (n != 2 || r[0] != 0)
        return kIOReturnError;
    *version = r[1];
    return kIOReturnSuccess;
}

IOReturn RTL8761BTFirmware::download(const uint8_t *data, size_t total) {
    size_t fragNum = total / kFragLen + 1;
    uint8_t cmd[1 + kFragLen];
    uint8_t j = 0;
    for (size_t i = 0; i < fragNum; i++) {
        size_t fragLen = kFragLen;
        cmd[0] = j++;
        if (cmd[0] == 0x7f)
            j = 1;
        if (i == fragNum - 1) {
            cmd[0] |= 0x80;  // last fragment
            fragLen = total % kFragLen;
        }
        memcpy(cmd + 1, data, fragLen);
        uint8_t r[8];
        uint32_t n = 0;
        IOReturn ret = hciCommand(kOpRtlDownload, cmd, (uint8_t)(fragLen + 1), r, sizeof(r), &n);
        if (ret != kIOReturnSuccess)
            return ret;
        if (n != 2 || r[0] != 0) {
            LOG("fragment %lu/%lu rejected (status 0x%02x)", (unsigned long)(i + 1), (unsigned long)fragNum, n ? r[0] : 0xff);
            return kIOReturnError;
        }
        data += kFragLen;
    }
    return kIOReturnSuccess;
}

IOReturn RTL8761BTFirmware::uploadIfNeeded() {
    LocalVersion before;
    IOReturn ret = readLocalVersion(&before);
    if (ret != kIOReturnSuccess)
        return ret;

    // Once firmware is running, hci_rev:lmp_subver report the firmware version (e.g. 0xdfc6d922).
    // This happens after a restart in which the dongle kept its power.
    if (before.manufacturer == kManufacturerRealtek && before.hciVer == kHciVer8761BU && before.lmpSubver != kROMLmpSubver) {
        LOG("firmware already loaded (version 0x%04x%04x); nothing to do", before.hciRev, before.lmpSubver);
        return kIOReturnSuccess;
    }
    if (before.lmpSubver != kROMLmpSubver || before.hciRev != kHciRev8761BU || before.hciVer != kHciVer8761BU) {
        LOG("chip not recognized as RTL8761BU");
        return kIOReturnUnsupported;
    }

    uint8_t rom = 0;
    ret = readRomVersion(&rom);
    if (ret != kIOReturnSuccess)
        return ret;

    size_t cap = rtl_epatch_max_payload(rtl8761bu_fw_bin_len, rtl8761bu_config_bin_len);
    auto payload = static_cast<uint8_t *>(IOMalloc(cap));
    if (!payload)
        return kIOReturnNoMemory;
    size_t payloadLen = 0;
    rtl_epatch_info info;
    const char *err = nullptr;
    if (rtl_epatch_build(rtl8761bu_fw_bin, rtl8761bu_fw_bin_len, rtl8761bu_config_bin, rtl8761bu_config_bin_len, rom, payload, cap,
                         &payloadLen, &info, &err) != 0) {
        LOG("embedded firmware is invalid: %s", err);
        IOFree(payload, cap);
        return kIOReturnError;
    }
    LOG("ROM %u: uploading %lu bytes (firmware 0x%08x)", rom, (unsigned long)payloadLen, info.fw_version);
    ret = download(payload, payloadLen);
    IOFree(payload, cap);
    if (ret != kIOReturnSuccess)
        return ret;

    LocalVersion after;
    ret = readLocalVersion(&after);
    if (ret != kIOReturnSuccess)
        return ret;
    if (after.lmpSubver == kROMLmpSubver) {
        LOG("the chip still reports its ROM version; the firmware did not load");
        return kIOReturnError;
    }
    LOG("firmware loaded (version 0x%04x%04x)", after.hciRev, after.lmpSubver);
    return kIOReturnSuccess;
}
