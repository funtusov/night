import Foundation
import IOKit

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("night-helper: \(message)\n").data(using: .utf8)!)
    exit(1)
}

private func clamp01(_ value: Double) -> Double {
    min(1.0, max(0.0, value))
}

private func parse01(_ raw: String) -> Double {
    guard let value = Double(raw), value.isFinite else {
        fail("invalid numeric value '\(raw)'")
    }
    if value < 0.0 || value > 1.0 {
        fail("value must be in [0, 1]")
    }
    return value
}

private func findBacklightService() -> io_service_t {
    IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"))
}

private func readDisplayBrightness() -> Double {
    let service = findBacklightService()
    guard service != 0 else {
        fail("AppleARMBacklight service not found")
    }
    defer { IOObjectRelease(service) }

    guard
        let params = IORegistryEntryCreateCFProperty(
            service,
            "IODisplayParameters" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any],
        let brightness = params["brightness"] as? [String: Any],
        let valueNumber = brightness["value"] as? NSNumber
    else {
        fail("failed to read display brightness")
    }

    let value = valueNumber.doubleValue
    return clamp01(value / 65536.0)
}

private func writeDisplayBrightness(_ value: Double) {
    let service = findBacklightService()
    guard service != 0 else {
        fail("AppleARMBacklight service not found")
    }
    defer { IOObjectRelease(service) }

    let normalized = clamp01(value)
    let scaled = Int((normalized * 65536.0).rounded())
    let result = IORegistryEntrySetCFProperty(service, "brightness" as CFString, scaled as CFTypeRef)
    guard result == KERN_SUCCESS else {
        fail("failed to set display brightness (kern=\(result))")
    }
}

private func createKeyboardClient() -> AnyObject {
    guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework") else {
        fail("CoreBrightness.framework not found")
    }
    if !bundle.isLoaded {
        _ = bundle.load()
    }
    guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else {
        fail("KeyboardBrightnessClient class not available")
    }
    return cls.init()
}

private func readKeyboardBrightness() -> Double {
    let client = createKeyboardClient()
    let selector = NSSelectorFromString("brightnessForKeyboard:")
    guard client.responds(to: selector) else {
        fail("brightnessForKeyboard: selector not available")
    }

    typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    let imp = client.method(for: selector)
    let fn = unsafeBitCast(imp, to: GetFn.self)
    let value = Double(fn(client, selector, 1))
    return clamp01(value)
}

private func writeKeyboardBrightness(_ value: Double) {
    let client = createKeyboardClient()
    let selector = NSSelectorFromString("setBrightness:forKeyboard:")
    guard client.responds(to: selector) else {
        fail("setBrightness:forKeyboard: selector not available")
    }

    typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    let imp = client.method(for: selector)
    let fn = unsafeBitCast(imp, to: SetFn.self)
    let ok = fn(client, selector, Float(clamp01(value)), 1)
    guard ok else {
        fail("failed to set keyboard brightness")
    }
}

private func readKeyboardAutoBrightness() -> Bool {
    let client = createKeyboardClient()
    let selector = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
    guard client.responds(to: selector) else {
        fail("isAutoBrightnessEnabledForKeyboard: selector not available")
    }

    typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    let imp = client.method(for: selector)
    let fn = unsafeBitCast(imp, to: GetFn.self)
    return fn(client, selector, 1)
}

private func writeKeyboardAutoBrightness(_ enabled: Bool) {
    let client = createKeyboardClient()
    let selector = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
    guard client.responds(to: selector) else {
        fail("enableAutoBrightness:forKeyboard: selector not available")
    }

    typealias SetFn = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    let imp = client.method(for: selector)
    let fn = unsafeBitCast(imp, to: SetFn.self)
    let ok = fn(client, selector, enabled, 1)
    guard ok else {
        fail("failed to set keyboard auto-brightness")
    }
}

let args = CommandLine.arguments
if args.count < 2 {
    fail("missing command")
}

switch args[1] {
case "display-get":
    print(String(format: "%.6f", readDisplayBrightness()))
case "display-set":
    guard args.count == 3 else {
        fail("usage: display-set <0..1>")
    }
    writeDisplayBrightness(parse01(args[2]))
case "keyboard-get":
    print(String(format: "%.6f", readKeyboardBrightness()))
case "keyboard-set":
    guard args.count == 3 else {
        fail("usage: keyboard-set <0..1>")
    }
    writeKeyboardBrightness(parse01(args[2]))
case "keyboard-auto-get":
    print(readKeyboardAutoBrightness() ? "1" : "0")
case "keyboard-auto-set":
    guard args.count == 3 else {
        fail("usage: keyboard-auto-set <0|1>")
    }
    switch args[2] {
    case "0":
        writeKeyboardAutoBrightness(false)
    case "1":
        writeKeyboardAutoBrightness(true)
    default:
        fail("keyboard-auto-set value must be 0 or 1")
    }
default:
    fail("unknown command '\(args[1])'")
}
