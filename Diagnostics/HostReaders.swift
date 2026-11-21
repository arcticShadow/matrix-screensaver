//
//  HostReaders.swift
//  Host vitals (load average, memory pressure, thermal state) and power
//  (battery level, power source): the value types the SYS panel shows, plus
//  the live readers `DiagnosticsEnvironment.live()` wires in. Tests inject
//  fakes instead. Readers are called on the poller's background queue.
//

import Foundation
import Darwin
import IOKit.ps

struct HostVitals: Equatable {
    enum MemoryPressure: Equatable { case normal, warn, critical }
    enum Thermal: Equatable { case nominal, fair, serious, critical }

    /// 1, 5 and 15 minute load averages.
    var load: [Double]
    var memoryPressure: MemoryPressure
    var thermal: Thermal
}

enum PowerStatus: Equatable {
    /// Desktop Mac: the panel omits the power line.
    case noBattery
    case battery(percent: Int, onAC: Bool, charging: Bool)
}

struct ReaderError: Error, CustomStringConvertible {
    var description: String
}

enum HostReaders {
    static func vitals() throws -> HostVitals {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) == 3 else { throw ReaderError(description: "getloadavg failed") }
        return HostVitals(load: load, memoryPressure: try memoryPressure(),
                          thermal: thermal(ProcessInfo.processInfo.thermalState))
    }

    /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical.
    static func memoryPressure() throws -> HostVitals.MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            throw ReaderError(description: "memory pressure sysctl failed")
        }
        switch level {
        case 4...: return .critical
        case 2...: return .warn
        default:   return .normal
        }
    }

    static func thermal(_ s: ProcessInfo.ThermalState) -> HostVitals.Thermal {
        switch s {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }

    /// IOKit power sources: the first internal battery, if any.
    static func power() throws -> PowerStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            throw ReaderError(description: "IOPSCopyPowerSourcesInfo failed")
        }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            throw ReaderError(description: "IOPSCopyPowerSourcesList failed")
        }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let pct = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            return .battery(percent: Swift.max(0, Swift.min(100, pct)),
                            onAC: d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                            charging: d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return .noBattery
    }
}
