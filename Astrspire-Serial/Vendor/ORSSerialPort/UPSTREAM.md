ORSSerialPort 2.1.0 from https://github.com/armadsen/ORSSerialPort/tree/2.1.0.
Swift Package Manager builds the local dependency with its original MIT license.

Astrspire patches ORSSerialPort.m to configure CS6 correctly, fail an open when
serial settings cannot be applied, apply framing before the custom baud ioctl,
bound stalled writes, avoid draining on close, and tolerate drivers that lack
modem line operations.

The path initializer also accepts Darwin pseudo terminals for loopback tests
and balances ownership of the IOKit device returned by path lookup.
The extended send method reports bytes accepted by the driver before an error.
