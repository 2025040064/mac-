import Foundation
import IOKit
import IOKit.serial
import ORSSerial

struct SerialDevice: Identifiable, Equatable {
    let path: String
    let name: String
    let usbIdentity: String?
    var id: String { path }
}

struct SerialSettings: Codable, Equatable {
    enum Parity: String, CaseIterable, Codable { case none = "None", odd = "Odd", even = "Even" }
    var baud = 115_200
    var dataBits = 8
    var stopBits = 1
    var parity = Parity.none
    var hardwareFlow = false
}

enum SerialEvent {
    case opened, closed, removed
    case error(String)
}

protocol SerialTransport: AnyObject {
    var event: ((SerialEvent) -> Void)? { get set }
    var received: ((Data) -> Void)? { get set }
    var sent: ((Data, Bool) -> Void)? { get set }
    func devices() -> [SerialDevice]
    func connect(_ device: SerialDevice, settings: SerialSettings)
    func disconnect()
    func send(_ data: Data)
}

/// Public methods and delegate delivery run on the main queue. Blocking port operations use io.
final class ORSSerialService: NSObject, SerialTransport, ORSSerialPortDelegate {
    var event: ((SerialEvent) -> Void)?
    var received: ((Data) -> Void)?
    var sent: ((Data, Bool) -> Void)?
    private let io = DispatchQueue(label: "Astrspire.serial", qos: .userInitiated)
    private var port: ORSSerialPort?
    private var closing = false

    func devices() -> [SerialDevice] {
        guard let match = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result = [SerialDevice]()
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            func property(_ key: String, parents: Bool = false) -> Any? {
                if parents {
                    return IORegistryEntrySearchCFProperty(device, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
                }
                return IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let path = property(kIOCalloutDeviceKey) as? String else { continue }
            let name = property(kIOTTYDeviceKey) as? String ?? URL(fileURLWithPath: path).lastPathComponent
            var identity: String?
            if let serial = property("USB Serial Number", parents: true) as? String, !serial.isEmpty,
               let vendor = property("idVendor", parents: true) as? NSNumber,
               let product = property("idProduct", parents: true) as? NSNumber {
                identity = "\(vendor):\(product):\(serial)"
            }
            result.append(SerialDevice(path: path, name: name, usbIdentity: identity))
        }
        return result.sorted { $0.path < $1.path }
    }

    func connect(_ device: SerialDevice, settings: SerialSettings) {
        guard port == nil else { return }
        guard let candidate = ORSSerialPort(path: device.path) else {
            event?(.error("串口设备已不可用：\(device.path)"))
            event?(.closed)
            return
        }
        candidate.delegate = self
        port = candidate
        closing = false
        io.async {
            candidate.allowsNonStandardBaudRates = true
            candidate.baudRate = NSNumber(value: settings.baud)
            candidate.numberOfDataBits = UInt(settings.dataBits)
            candidate.numberOfStopBits = UInt(settings.stopBits)
            candidate.usesRTSCTSFlowControl = settings.hardwareFlow
            switch settings.parity {
            case .none: candidate.parity = .none
            case .odd: candidate.parity = .odd
            case .even: candidate.parity = .even
            }
            candidate.open()
        }
    }

    func disconnect() {
        guard let port, !closing else { return }
        closing = true
        io.async {
            if !port.isOpen {
                DispatchQueue.main.async { self.release(port) }
            } else {
                _ = port.close()
            }
        }
    }

    func send(_ data: Data) {
        guard let port, !closing else { sent?(Data(), false); return }
        io.async {
            var written: UInt = 0
            let success = port.send(data, writtenCount: &written)
            let accepted = Data(data.prefix(Int(written)))
            DispatchQueue.main.async { self.sent?(accepted, success) }
        }
    }

    private func release(_ candidate: ORSSerialPort) {
        guard candidate === port else { return }
        candidate.delegate = nil
        port = nil
        closing = false
        event?(.closed)
    }

    func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        if serialPort === port { received?(data) }
    }

    func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        if serialPort === port, !closing { event?(.opened) }
    }

    func serialPortWasClosed(_ serialPort: ORSSerialPort) { release(serialPort) }

    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        guard serialPort === port else { return }
        closing = true
        event?(.removed)
    }

    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        guard serialPort === port else { return }
        event?(.error(error.localizedDescription))
        if !serialPort.isOpen { release(serialPort) }
    }
}
