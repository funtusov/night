import Foundation
import CoreGraphics
import Darwin
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

private struct DisplayLevel: Codable {
    let id: String
    let value: Double
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            fail("failed to encode JSON output")
        }
        print(text)
    } catch {
        fail("failed to encode JSON output: \(error)")
    }
}

private func findBacklightService() -> io_service_t {
    IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"))
}

private func readDisplayBrightnessBacklight() -> Double {
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

private func writeDisplayBrightnessBacklight(_ value: Double) {
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

private typealias DisplayGetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DisplaySetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

private struct DisplayServicesAPI {
    let handle: UnsafeMutableRawPointer
    let get: DisplayGetFn
    let set: DisplaySetFn
}

private let displayServicesAPI: DisplayServicesAPI? = {
    let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    guard let handle = dlopen(path, RTLD_LAZY) else {
        return nil
    }

    guard
        let getSym = dlsym(handle, "DisplayServicesGetBrightness"),
        let setSym = dlsym(handle, "DisplayServicesSetBrightness")
    else {
        dlclose(handle)
        return nil
    }

    let getFn = unsafeBitCast(getSym, to: DisplayGetFn.self)
    let setFn = unsafeBitCast(setSym, to: DisplaySetFn.self)
    return DisplayServicesAPI(handle: handle, get: getFn, set: setFn)
}()

private func activeDisplayIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    let result = CGGetActiveDisplayList(UInt32(ids.count), &ids, &count)
    guard result == .success else {
        return []
    }
    return Array(ids.prefix(Int(count)))
}

private func readDisplayLevelsDisplayServices() -> [DisplayLevel] {
    guard let api = displayServicesAPI else {
        return []
    }

    var levels: [DisplayLevel] = []
    for id in activeDisplayIDs() {
        var value: Float = -1
        let rc = api.get(id, &value)
        if rc == 0 && value.isFinite {
            levels.append(DisplayLevel(id: "display:\(id)", value: clamp01(Double(value))))
        }
    }
    return levels
}

@discardableResult
private func writeDisplayLevelDisplayServices(id: CGDirectDisplayID, value: Double) -> Bool {
    guard let api = displayServicesAPI else {
        return false
    }
    let rc = api.set(id, Float(clamp01(value)))
    return rc == 0
}

private func readDisplayLevels() -> [DisplayLevel] {
    let displayServiceLevels = readDisplayLevelsDisplayServices()
    if !displayServiceLevels.isEmpty {
        return displayServiceLevels
    }
    return [DisplayLevel(id: "builtin", value: readDisplayBrightnessBacklight())]
}

private func writeDisplayAll(_ value: Double) {
    let displayServiceLevels = readDisplayLevelsDisplayServices()
    if !displayServiceLevels.isEmpty {
        for level in displayServiceLevels {
            let raw = String(level.id.dropFirst("display:".count))
            guard let id = UInt32(raw), writeDisplayLevelDisplayServices(id: id, value: value) else {
                fail("failed to set display brightness for \(level.id)")
            }
        }
        return
    }
    writeDisplayBrightnessBacklight(value)
}

private func writeDisplayOne(idToken: String, value: Double) {
    if idToken == "builtin" {
        writeDisplayBrightnessBacklight(value)
        return
    }
    if idToken.hasPrefix("display:") {
        let raw = String(idToken.dropFirst("display:".count))
        guard let id = UInt32(raw) else {
            fail("invalid display id token '\(idToken)'")
        }
        guard writeDisplayLevelDisplayServices(id: id, value: value) else {
            fail("failed to set display brightness for \(idToken)")
        }
        return
    }
    fail("invalid display id token '\(idToken)'")
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
    let levels = readDisplayLevels()
    if let first = levels.first {
        print(String(format: "%.6f", first.value))
    } else {
        fail("no controllable display brightness source found")
    }
case "display-set":
    guard args.count == 3 else {
        fail("usage: display-set <0..1>")
    }
    writeDisplayAll(parse01(args[2]))
case "display-all-get":
    printJSON(readDisplayLevels())
case "display-all-set":
    guard args.count == 3 else {
        fail("usage: display-all-set <0..1>")
    }
    writeDisplayAll(parse01(args[2]))
case "display-one-set":
    guard args.count == 4 else {
        fail("usage: display-one-set <display:id|builtin> <0..1>")
    }
    writeDisplayOne(idToken: args[2], value: parse01(args[3]))
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
