// SPDX-License-Identifier: GPL-2.0-or-later
//
// RTL8761BTFirmware: uploads the Realtek RTL8761BU/BUV firmware to USB Bluetooth dongles at boot,
// then releases the device to the macOS Bluetooth stack (bluetoothd + BlueToolFixup).
#pragma once

#include <IOKit/IOLocks.h>
#include <IOKit/IOService.h>
#include <IOKit/usb/IOUSBHostDevice.h>
#include <IOKit/usb/IOUSBHostInterface.h>
#include <IOKit/usb/IOUSBHostPipe.h>

class RTL8761BTFirmware : public IOService {
    OSDeclareDefaultStructors(RTL8761BTFirmware)

public:
    bool start(IOService *provider) override;

private:
    struct LocalVersion {
        uint8_t hciVer, lmpVer;
        uint16_t hciRev, manufacturer, lmpSubver;
    };

    IOUSBHostDevice *device = nullptr;
    IOUSBHostInterface *interface = nullptr;
    IOUSBHostPipe *eventPipe = nullptr;
    IOBufferMemoryDescriptor *eventBuffer = nullptr;
    uint16_t eventPacketSize = 0;
    IOLock *ioLock = nullptr;

    IOReturn openDongle(IOUSBHostDevice *dev);
    void closeDongle();
    IOReturn uploadIfNeeded();

    IOReturn sendCommandPacket(uint16_t opcode, const void *params, uint8_t plen);
    IOReturn readEventPacket(uint8_t *out, uint32_t *len, uint32_t timeoutMs);
    IOReturn readEvent(uint8_t *out, uint32_t cap, uint32_t *len, uint32_t timeoutMs);
    IOReturn hciCommand(uint16_t opcode, const void *params, uint8_t plen, uint8_t *reply, uint32_t replyCap, uint32_t *replyLen);
    IOReturn readLocalVersion(LocalVersion *v);
    IOReturn readRomVersion(uint8_t *version);
    IOReturn download(const uint8_t *data, size_t total);

    static void eventReadCompleted(void *owner, void *parameter, IOReturn status, uint32_t bytesTransferred);
};
