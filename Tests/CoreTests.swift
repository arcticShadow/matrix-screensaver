//
//  CoreTests.swift — the top seam: a fake environment (home dir, config file,
//  clock, boot time) in, panels + overlay switch out. This is how later
//  tickets should test new sources: build a fake home tree, inject it here.
//

import Foundation

/// A fake environment rooted at a scratch home directory, with a settable clock.
final class FakeWorld {
    let home: String
    var now: Date
    var boot: Date

    // Injected host readers. Each call counts, advances the fake clock by the
    // configured fetch duration (a "fake fetch time"), then returns or throws.
    var vitals = HostVitals(load: [0.42, 0.38, 0.31], memoryPressure: .normal, thermal: .nominal)
    var vitalsDuration: TimeInterval = 0.001
    var vitalsFail = false
    var vitalsCalls = 0
    var power: PowerStatus = .battery(percent: 87, onAC: false, charging: false)
    var powerDuration: TimeInterval = 0.002
    var powerFail = false
    var powerCalls = 0
    struct FakeFailure: Error {}

    init(_ name: String, now: Date = Date(timeIntervalSince1970: 1_795_271_405)) {
        home = makeTempDir(name)
        self.now = now
        boot = now.addingTimeInterval(-(2 * 86400 + 5 * 3600))
    }
    var configPath: String { ConfigLoader.defaultPath(home: home) }
    func writeConfig(_ json: String) { writeFile(configPath, json) }
    var env: DiagnosticsEnvironment {
        DiagnosticsEnvironment(now: { [unowned self] in self.now },
                               homeDirectory: home,
                               configPath: configPath,
                               bootTime: boot,
                               timeZone: { TimeZone(identifier: "UTC")! },
                               readVitals: { [unowned self] in
                                   self.vitalsCalls += 1
                                   self.now = self.now.addingTimeInterval(self.vitalsDuration)
                                   if self.vitalsFail { throw FakeFailure() }
                                   return self.vitals
                               },
                               readPower: { [unowned self] in
                                   self.powerCalls += 1
                                   self.now = self.now.addingTimeInterval(self.powerDuration)
                                   if self.powerFail { throw FakeFailure() }
                                   return self.power
                               })
    }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

func coreTests() {
    test("no config file: overlay on, SYS panel present") {
        let w = FakeWorld("core-default")
        let core = DiagnosticsCore(env: w.env)
        expect(core.overlayEnabled)
        expectEqual(core.configStatus, .missing)
        expectEqual(core.panels().map(\.title), ["SYS"])
    }

    test("config overlay:false disables the overlay and yields no panels") {
        let w = FakeWorld("core-off")
        w.writeConfig(#"{ "overlay": false }"#)
        let core = DiagnosticsCore(env: w.env)
        expect(!core.overlayEnabled)
        expectEqual(core.panels(), [])
    }

    test("panels tick with the injected clock; saver uptime counts from core creation") {
        let w = FakeWorld("core-tick")
        let core = DiagnosticsCore(env: w.env)
        expectEqual(core.panels().first?.value(of: "SYS.CLOCK"), "14:30:05")
        expectEqual(core.panels().first?.value(of: "SAVER.UPTIME"), "00:00:00")
        expectEqual(core.panels().first?.value(of: "CONSTRUCT.UPTIME"), "2d 05:00")
        w.now = w.now.addingTimeInterval(61)
        expectEqual(core.panels().first?.value(of: "SYS.CLOCK"), "14:31:06")
        expectEqual(core.panels().first?.value(of: "SAVER.UPTIME"), "00:01:01")
    }

    test("live environment resolves the real (passwd) home, not a container") {
        let env = DiagnosticsEnvironment.live()
        expect(env.homeDirectory.hasPrefix("/"), "home should be absolute")
        expect(!env.homeDirectory.contains("/Library/Containers/"), "home must not be a sandbox container")
        expectEqual(env.configPath, env.homeDirectory + "/.config/matrix-diag/config.json")
        expect(env.bootTime < env.now(), "boot time should be in the past")
    }
}
