import AppKit
import Foundation

struct AppIdentity: Codable {
    let appPath: String
    let bundleID: String
    let displayName: String
}

struct LaunchResult: Codable {
    let ok: Bool
    let appPath: String?
    let bundleID: String?
    let displayName: String?
    let pid: Int32?
    let reason: String?
}

func appBundle(at url: URL) -> AppIdentity? {
    let resolvedURL=url.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedURL.pathExtension.lowercased() == "app",
          let bundle = Bundle(url: resolvedURL),
          let bundleID = bundle.bundleIdentifier else { return nil }
    let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? resolvedURL.deletingPathExtension().lastPathComponent
    return AppIdentity(appPath: resolvedURL.path, bundleID: bundleID, displayName: displayName)
}

func nestedAppBundles(in directory: URL) -> [AppIdentity] {
    let fileManager=FileManager.default
    var visited=Set<String>()
    var result: [AppIdentity] = []
    func visit(_ parent:URL) {
        let canonical=parent.resolvingSymlinksInPath().standardizedFileURL
        guard visited.insert(canonical.path).inserted,
              let children=try? fileManager.contentsOfDirectory(at:parent,
                includingPropertiesForKeys:[.isDirectoryKey,.isPackageKey],options:[]) else{return}
        for child in children {
            if child.lastPathComponent.hasPrefix(".") { continue }
            if child.pathExtension.lowercased()=="app" {
                if let identity=appBundle(at:child) { result.append(identity) }
                let wrapper=child.appendingPathComponent("Wrapper",isDirectory:true)
                if fileManager.fileExists(atPath:wrapper.path) { visit(wrapper) }
                continue
            }
            let values=try? child.resourceValues(forKeys:[.isDirectoryKey,.isPackageKey])
            if values?.isDirectory==true && values?.isPackage != true { visit(child) }
        }
    }
    visit(directory)
    return result
}

func searchRoots() -> [URL] {
    let fileManager = FileManager.default
    let homeApplications = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    return [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        homeApplications,
    ].filter { fileManager.fileExists(atPath: $0.path) }
}

func resolve(_ selector: String, roots: [URL] = searchRoots()) throws -> AppIdentity {
    guard !selector.isEmpty, !selector.contains("\n"), !selector.contains("\0") else {
        throw NSError(domain: "CodexNativeApp", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid_application_selector"])
    }

    let fileManager = FileManager.default
    if selector.hasPrefix("/") {
        let url = URL(fileURLWithPath: selector).resolvingSymlinksInPath().standardizedFileURL
        if url.pathExtension.lowercased() == "app", let identity = appBundle(at: url) {
            return identity
        }
        if fileManager.fileExists(atPath: url.path) {
            let nested = nestedAppBundles(in: url)
            if nested.count == 1, let identity = nested.first { return identity }
            if nested.count > 1 {
                throw NSError(domain: "CodexNativeApp", code: 2, userInfo: [NSLocalizedDescriptionKey: "application_path_is_ambiguous"])
            }
        }
        throw NSError(domain: "CodexNativeApp", code: 3, userInfo: [NSLocalizedDescriptionKey: "application_path_not_found"])
    }

    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: selector),
       let identity = appBundle(at: url) {
        return identity
    }

    let wanted = selector.replacingOccurrences(of: ".app", with: "", options: [.caseInsensitive, .backwards])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var matches: [AppIdentity] = []
    for root in roots {
        for identity in nestedAppBundles(in: root) {
            if identity.displayName.caseInsensitiveCompare(wanted) == .orderedSame
                || URL(fileURLWithPath: identity.appPath).deletingPathExtension().lastPathComponent
                    .caseInsensitiveCompare(wanted) == .orderedSame {
                matches.append(identity)
            }
        }
    }
    let unique = Dictionary(matches.map { ($0.appPath, $0) }, uniquingKeysWith: { first, _ in first }).values
    let resolved = Array(unique)
    guard resolved.count == 1, let identity = resolved.first else {
        let reason = resolved.isEmpty ? "application_not_found" : "application_name_is_ambiguous"
        throw NSError(domain: "CodexNativeApp", code: 4, userInfo: [NSLocalizedDescriptionKey: reason])
    }
    return identity
}

func emit<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
          let line = String(data: data, encoding: .utf8) else {
        print("{\"ok\":false,\"reason\":\"json_encode_failed\"}")
        exit(2)
    }
    print(line)
}

func runLauncher() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count == 2 else {
        emit(LaunchResult(ok: false, appPath: nil, bundleID: nil, displayName: nil, pid: nil, reason: "usage"))
        exit(2)
    }
    let action = arguments[0]
    do {
        let identity = try resolve(arguments[1])
        if action == "resolve" {
            emit(identity)
            return
        }
        guard action == "launch" else {
            emit(LaunchResult(ok: false, appPath: nil, bundleID: nil, displayName: nil, pid: nil, reason: "unsupported_action"))
            exit(2)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        let semaphore = DispatchSemaphore(value: 0)
        var result: LaunchResult?
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: identity.appPath),
                                           configuration: configuration) { application, error in
            if let application, application.bundleIdentifier == identity.bundleID {
                result = LaunchResult(ok: true, appPath: identity.appPath, bundleID: identity.bundleID,
                                      displayName: identity.displayName, pid: application.processIdentifier, reason: nil)
            } else {
                result = LaunchResult(ok: false, appPath: identity.appPath, bundleID: identity.bundleID,
                                      displayName: identity.displayName, pid: nil,
                                      reason: error?.localizedDescription ?? "application_launch_failed")
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            emit(LaunchResult(ok: false, appPath: identity.appPath, bundleID: identity.bundleID,
                              displayName: identity.displayName, pid: nil, reason: "application_launch_timed_out"))
            exit(2)
        }
        guard let result else {
            emit(LaunchResult(ok: false, appPath: identity.appPath, bundleID: identity.bundleID,
                              displayName: identity.displayName, pid: nil, reason: "application_launch_failed"))
            exit(2)
        }
        emit(result)
        if !result.ok { exit(2) }
    } catch {
        emit(LaunchResult(ok: false, appPath: nil, bundleID: nil, displayName: nil, pid: nil,
                          reason: error.localizedDescription))
        exit(2)
    }
}

#if !NATIVE_APP_LAUNCHER_LIBRARY
@main
struct NativeAppLauncherCLI {
    static func main() { runLauncher() }
}
#endif
