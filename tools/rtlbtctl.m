// SPDX-License-Identifier: GPL-2.0-or-later
//
// rtlbtctl: userspace test tool for Realtek RTL8761BU/BUV USB Bluetooth dongles.
//
// Talks to the dongle directly over USB, without the kext: reads the chip version, uploads the
// firmware (same protocol as Linux drivers/bluetooth/btrtl.c) and checks that it loaded.
// The firmware goes to the chip's RAM and is lost when the dongle loses power (just replug it).
// Only works while nothing else (e.g. bluetoothd) has the dongle open.
//
// Usage:
//   rtlbtctl parse  <fw.bin> <config.bin> <rom_version>   (reads the files only; no USB access)
//   rtlbtctl info                                          (reads versions only)
//   rtlbtctl upload <fw.bin> <config.bin>
//   rtlbtctl drop                                          (discards the loaded firmware)

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOUSBHost/IOUSBHost.h>

#include "../src/rtl_epatch.h"

static const uint16_t kVendorID = 0x2B89;   // UGREEN
static const uint16_t kProductID = 0x6275;  // RTL8761BUV

// Values reported by the chip before any firmware is loaded ("8761BU" entry in btrtl.c)
static const uint16_t kROMLmpSubver = 0x8761;
static const uint16_t kHciRev8761BU = 0x000b;
static const uint8_t kHciVer8761BU = 0x0a;

static const uint16_t kOpReadLocalVersion = 0x1001;
static const uint16_t kOpRtlDownload = 0xfc20;
static const uint16_t kOpRtlDropFirmware = 0xfc66;
static const uint16_t kOpRtlReadRomVersion = 0xfc6d;
static const size_t kFragLen = 252;
static const NSTimeInterval kCmdTimeout = 5.0;

#pragma mark - Firmware (parser shared with the kext: src/rtl_epatch.c)

static uint16_t LE16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

static NSData *BuildPayload(NSData *fw, NSData *cfg, uint8_t romVersion, NSString **err) {
    size_t cap = rtl_epatch_max_payload(fw.length, cfg.length), len = 0;
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    rtl_epatch_info info;
    const char *e = NULL;
    if (rtl_epatch_build(fw.bytes, fw.length, cfg.bytes, cfg.length, romVersion, out.mutableBytes, cap, &len, &info, &e) != 0) {
        *err = @(e);
        return nil;
    }
    out.length = len;
    printf("firmware: version 0x%08x, %u patches, project ID %d; patch for ROM %u: %u bytes at 0x%x; "
           "config: %lu bytes; payload: %lu bytes (%lu fragments)\n",
           info.fw_version, info.num_patches, info.project_id, romVersion, info.patch_len, info.patch_off,
           (unsigned long)cfg.length, (unsigned long)len, (unsigned long)(len / kFragLen + 1));
    return out;
}

#pragma mark - USB / HCI

static IOUSBHostDevice *gDevice;
static IOUSBHostInterface *gInterface;
static IOUSBHostPipe *gEventPipe;
static NSUInteger gEventPacketSize;

static void Fail(NSString *msg, NSError *e) {
    fprintf(stderr, "error: %s%s%s\n", msg.UTF8String, e ? ": " : "", e ? e.localizedDescription.UTF8String : "");
    exit(1);
}

// Finds interface 0 among the device's children (it only exists once the device is configured).
static io_service_t FindInterface0(void) {
    for (int attempt = 0; attempt < 40; attempt++) {
        io_iterator_t it;
        if (IORegistryEntryCreateIterator(gDevice.ioService, kIOServicePlane, 0, &it) == KERN_SUCCESS) {
            io_service_t child;
            while ((child = IOIteratorNext(it))) {
                if (IOObjectConformsTo(child, "IOUSBHostInterface")) {
                    CFTypeRef n = IORegistryEntryCreateCFProperty(child, CFSTR("bInterfaceNumber"), kCFAllocatorDefault, 0);
                    BOOL isZero = n && [(__bridge NSNumber *)n intValue] == 0;
                    if (n)
                        CFRelease(n);
                    if (isZero) {
                        IOObjectRelease(it);
                        return child;
                    }
                }
                IOObjectRelease(child);
            }
            IOObjectRelease(it);
        }
        usleep(50 * 1000);
    }
    return IO_OBJECT_NULL;
}

static void OpenDongle(void) {
    CFMutableDictionaryRef match = [IOUSBHostDevice createMatchingDictionaryWithVendorID:@(kVendorID)
                                                                              productID:@(kProductID)
                                                                              bcdDevice:nil
                                                                            deviceClass:nil
                                                                         deviceSubclass:nil
                                                                         deviceProtocol:nil
                                                                                  speed:nil
                                                                         productIDArray:nil];
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!svc)
        Fail([NSString stringWithFormat:@"dongle %04X:%04X not found on USB", kVendorID, kProductID], nil);

    NSError *e = nil;
    gDevice = [[IOUSBHostDevice alloc] initWithIOService:svc options:IOUSBHostObjectInitOptionsNone queue:nil error:&e interestHandler:nil];
    IOObjectRelease(svc);
    if (!gDevice)
        Fail(@"could not open the device (is bluetoothd using it?)", e);

    // If unconfigured, select configuration 1. matchInterfaces:NO keeps other drivers off the interfaces.
    const IOUSBConfigurationDescriptor *current = gDevice.configurationDescriptor;
    if (!current && ![gDevice configureWithValue:1 matchInterfaces:NO error:&e])
        Fail(@"could not configure the device", e);

    io_service_t intfSvc = FindInterface0();
    if (!intfSvc)
        Fail(@"interface 0 did not show up after configuring", nil);
    gInterface = [[IOUSBHostInterface alloc] initWithIOService:intfSvc options:IOUSBHostObjectInitOptionsNone queue:nil error:&e interestHandler:nil];
    IOObjectRelease(intfSvc);
    if (!gInterface)
        Fail(@"could not open interface 0", e);

    // HCI event endpoint: the interrupt IN endpoint of interface 0.
    const IOUSBConfigurationDescriptor *config = gInterface.configurationDescriptor;
    const IOUSBInterfaceDescriptor *intf = gInterface.interfaceDescriptor;
    const IOUSBEndpointDescriptor *ep = NULL;
    while ((ep = IOUSBGetNextEndpointDescriptor(config, intf, (const IOUSBDescriptorHeader *)ep))) {
        if (IOUSBGetEndpointType(ep) == kIOUSBEndpointTypeInterrupt && IOUSBGetEndpointDirection(ep) == kIOUSBEndpointDirectionIn)
            break;
    }
    if (!ep)
        Fail(@"event endpoint (interrupt IN) not found", nil);
    gEventPacketSize = OSSwapLittleToHostInt16(ep->wMaxPacketSize) & 0x7ff;
    gEventPipe = [gInterface copyPipeWithAddress:ep->bEndpointAddress error:&e];
    if (!gEventPipe)
        Fail(@"could not open the event endpoint", e);
    printf("dongle %04X:%04X opened; events on endpoint 0x%02x (%lu bytes per packet)\n", kVendorID, kProductID,
           ep->bEndpointAddress, (unsigned long)gEventPacketSize);
}

static void CloseDongle(void) {
    [gEventPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
    [gInterface destroy];
    [gDevice destroy];
}

// Reads one packet from the event endpoint with our own timeout (interrupt pipes take none).
static NSData *ReadEventPacket(NSTimeInterval timeout) {
    NSError *e = nil;
    NSMutableData *buf = [gInterface ioDataWithCapacity:gEventPacketSize error:&e];
    if (!buf)
        Fail(@"out of memory for the event buffer", e);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block IOReturn status = kIOReturnError;
    __block NSUInteger got = 0;
    BOOL ok = [gEventPipe enqueueIORequestWithData:buf completionTimeout:0 error:&e completionHandler:^(IOReturn s, NSUInteger n) {
        status = s;
        got = n;
        dispatch_semaphore_signal(done);
    }];
    if (!ok)
        Fail(@"could not queue an event read", e);
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        [gEventPipe abortWithOption:IOUSBHostAbortOptionSynchronous error:nil];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);  // aborting completes the pending read
        return nil;
    }
    return status == kIOReturnSuccess ? [buf subdataWithRange:NSMakeRange(0, got)] : nil;
}

// An HCI event may span several packets: read until we have the 2-byte header plus its parameters.
static NSData *ReadEvent(NSTimeInterval timeout) {
    NSMutableData *evt = [NSMutableData data];
    while (evt.length < 2 || evt.length < 2 + ((const uint8_t *)evt.bytes)[1]) {
        NSData *pkt = ReadEventPacket(timeout);
        if (!pkt)
            return nil;
        [evt appendData:pkt];
    }
    return evt;
}

static void SendCommandPacket(uint16_t opcode, const void *params, uint8_t plen) {
    NSError *e = nil;
    NSMutableData *pkt = [gDevice ioDataWithCapacity:3 + plen error:&e];
    if (!pkt)
        Fail(@"out of memory for the command", e);
    uint8_t *b = pkt.mutableBytes;
    b[0] = opcode & 0xff;
    b[1] = opcode >> 8;
    b[2] = plen;
    if (plen)
        memcpy(b + 3, params, plen);
    // HCI command over USB: class request on the default control endpoint (Bluetooth Core, USB transport)
    IOUSBDeviceRequest req = {.bmRequestType = 0x20, .bRequest = 0, .wValue = 0, .wIndex = 0, .wLength = (uint16_t)(3 + plen)};
    NSUInteger sent = 0;
    if (![gDevice sendDeviceRequest:req data:pkt bytesTransferred:&sent completionTimeout:kCmdTimeout error:&e])
        Fail([NSString stringWithFormat:@"could not send command 0x%04x", opcode], e);
}

// Sends a command and returns the Command Complete parameters (starting at the status byte).
static NSData *HCICommand(uint16_t opcode, const void *params, uint8_t plen) {
    SendCommandPacket(opcode, params, plen);
    for (int ignored = 0; ignored <= 32; ignored++) {
        NSData *evt = ReadEvent(kCmdTimeout);
        if (!evt)
            Fail([NSString stringWithFormat:@"no reply to command 0x%04x", opcode], nil);
        const uint8_t *b = evt.bytes;
        if (b[0] == 0x0e && evt.length >= 6 && LE16(b + 3) == opcode)
            return [evt subdataWithRange:NSMakeRange(5, evt.length - 5)];
        if (b[0] == 0x0f && evt.length >= 6 && LE16(b + 4) == opcode)
            Fail([NSString stringWithFormat:@"command 0x%04x rejected (Command Status 0x%02x)", opcode, b[2]], nil);
        printf("  (ignored event: 0x%02x, %lu bytes)\n", b[0], (unsigned long)evt.length);
    }
    Fail([NSString stringWithFormat:@"command 0x%04x: too many unrelated events", opcode], nil);
    return nil;
}

typedef struct {
    uint8_t hciVer, lmpVer;
    uint16_t hciRev, manufacturer, lmpSubver;
} LocalVersion;

static LocalVersion ReadLocalVersion(void) {
    NSData *r = HCICommand(kOpReadLocalVersion, NULL, 0);
    const uint8_t *b = r.bytes;
    if (r.length < 9 || b[0] != 0)
        Fail(@"Read Local Version failed", nil);
    LocalVersion v = {.hciVer = b[1], .hciRev = LE16(b + 2), .lmpVer = b[4], .manufacturer = LE16(b + 5), .lmpSubver = LE16(b + 7)};
    printf("version: hci_ver=0x%02x hci_rev=0x%04x lmp_ver=0x%02x manufacturer=0x%04x lmp_subver=0x%04x\n", v.hciVer, v.hciRev,
           v.lmpVer, v.manufacturer, v.lmpSubver);
    return v;
}

static BOOL IsRom8761BU(LocalVersion v) {
    return v.lmpSubver == kROMLmpSubver && v.hciRev == kHciRev8761BU && v.hciVer == kHciVer8761BU;
}

static uint8_t ReadRomVersion(void) {
    NSData *r = HCICommand(kOpRtlReadRomVersion, NULL, 0);
    const uint8_t *b = r.bytes;
    if (r.length != 2 || b[0] != 0)
        Fail(@"Read ROM Version failed", nil);
    printf("ROM: version %u\n", b[1]);
    return b[1];
}

static void Download(NSData *payload) {
    const uint8_t *data = payload.bytes;
    size_t total = payload.length;
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
        NSData *r = HCICommand(kOpRtlDownload, cmd, (uint8_t)(fragLen + 1));
        const uint8_t *b = r.bytes;
        if (r.length != 2 || b[0] != 0)
            Fail([NSString stringWithFormat:@"fragment %zu/%zu rejected (status 0x%02x)", i + 1, fragNum, r.length ? b[0] : 0xff], nil);
        data += kFragLen;
        printf("\r  uploading: %zu/%zu", i + 1, fragNum);
        fflush(stdout);
    }
    printf("\n");
}

#pragma mark - Commands

static NSData *ReadFile(const char *path) {
    NSData *d = [NSData dataWithContentsOfFile:@(path)];
    if (!d)
        Fail([NSString stringWithFormat:@"could not read %s", path], nil);
    return d;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *cmd = argc > 1 ? @(argv[1]) : @"";
        NSString *err = nil;

        if ([cmd isEqualToString:@"parse"] && argc == 5) {
            if (!BuildPayload(ReadFile(argv[2]), ReadFile(argv[3]), (uint8_t)atoi(argv[4]), &err))
                Fail(err, nil);
            return 0;
        }
        if ([cmd isEqualToString:@"info"]) {
            OpenDongle();
            LocalVersion v = ReadLocalVersion();
            if (IsRom8761BU(v)) {
                printf("chip: RTL8761BU/BUV without firmware (factory state)\n");
                ReadRomVersion();
            } else if (v.manufacturer == 0x005d && v.hciVer == kHciVer8761BU && v.lmpSubver != kROMLmpSubver) {
                // Once firmware is running, hci_rev:lmp_subver report the firmware version (e.g. 0xdfc6d922)
                printf("chip: Realtek with firmware already loaded (version 0x%04x%04x)\n", v.hciRev, v.lmpSubver);
            } else {
                printf("chip: not recognized as RTL8761BU\n");
            }
            CloseDongle();
            return 0;
        }
        if ([cmd isEqualToString:@"upload"] && argc == 4) {
            NSData *fw = ReadFile(argv[2]), *cfg = ReadFile(argv[3]);
            OpenDongle();
            LocalVersion before = ReadLocalVersion();
            if (!IsRom8761BU(before))
                Fail(before.lmpSubver != kROMLmpSubver ? @"firmware is already loaded (run 'drop' first or replug the dongle)"
                                                       : @"the chip is not the expected RTL8761BU",
                     nil);
            uint8_t rom = ReadRomVersion();
            NSData *payload = BuildPayload(fw, cfg, rom, &err);
            if (!payload)
                Fail(err, nil);
            Download(payload);
            LocalVersion after = ReadLocalVersion();
            CloseDongle();
            if (after.lmpSubver == kROMLmpSubver)
                Fail(@"the chip still reports its ROM version; the firmware did not load", nil);
            printf("OK: firmware loaded (lmp_subver 0x%04x -> 0x%04x)\n", before.lmpSubver, after.lmpSubver);
            return 0;
        }
        if ([cmd isEqualToString:@"drop"]) {
            OpenDongle();
            SendCommandPacket(kOpRtlDropFirmware, NULL, 0);  // no reply, same as Linux
            usleep(200 * 1000);
            ReadLocalVersion();
            CloseDongle();
            return 0;
        }
        fprintf(stderr, "usage:\n  rtlbtctl parse <fw.bin> <config.bin> <rom_version>\n  rtlbtctl info\n"
                        "  rtlbtctl upload <fw.bin> <config.bin>\n  rtlbtctl drop\n");
        return 2;
    }
}
