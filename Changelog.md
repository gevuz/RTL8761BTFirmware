RTL8761BTFirmware Changelog
===========================

#### v0.1.0
- Initial release
- Uploads the linux-firmware `rtl8761bu` firmware to Realtek RTL8761BU/BUV USB dongles at boot, then releases the device to `bluetoothd` (requires BlueToolFixup)
- Supported device: UGREEN USB Bluetooth 5.0 adapter (`2B89:6275`)
- Skips the upload when firmware is already running
- Added `-rtlbtoff` boot-arg to disable the kext
- Added `rtlbtctl`, a userspace test tool sharing the firmware parser with the kext
