import ApplicationServices
import Foundation

struct Snapshot: Encodable {
    let role: String
    let label: String
    let value: String
    let actions: [String]
}

struct Requirement: Encodable {
    let label: String
    let role: String
    let requiresValue: Bool
    let requiresPressAction: Bool
}

struct Check: Encodable {
    let requirement: Requirement
    let passed: Bool
    let matched: Snapshot?
}

struct Report: Encodable {
    let schemaVersion = 1
    let generatedAt = Date()
    let gate = "G4-accessibility-runtime"
    let result: String
    let evidenceLevel = "E4-installed-native-app-system-AX"
    let accessibilityTrusted: Bool
    let processIdentifier: Int32
    let windowCount: Int
    let visitedElementCount: Int
    let checks: [Check]
    let privacy = "Only stable accessibility roles, required labels, value presence, and action names are recorded."
}

func option(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          CommandLine.arguments.indices.contains(index + 1) else { return nil }
    return CommandLine.arguments[index + 1]
}

guard let pidText = option("--pid"), let pid = pid_t(pidText),
      let reportPath = option("--report") else {
    FileHandle.standardError.write(Data("Usage: --pid <pid> --report <path>\n".utf8))
    exit(64)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

func snapshot(_ element: AXUIElement) -> Snapshot {
    let title = string(element, kAXTitleAttribute)
    let description = string(element, kAXDescriptionAttribute)
    let rawValue = attribute(element, kAXValueAttribute)
    var actions: CFArray?
    _ = AXUIElementCopyActionNames(element, &actions)
    return Snapshot(
        role: string(element, kAXRoleAttribute),
        label: title.isEmpty ? description : title,
        value: rawValue.map { String(describing: $0) } ?? "",
        actions: actions as? [String] ?? []
    )
}

let application = AXUIElementCreateApplication(pid)
let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
var elements: [Snapshot] = []
var visited = 0
var visitedIdentities = Set<CFHashCode>()

func walk(_ element: AXUIElement, depth: Int) {
    guard depth < 20, visited < 10_000 else { return }
    let identity = CFHash(element)
    guard visitedIdentities.insert(identity).inserted else { return }
    visited += 1
    elements.append(snapshot(element))
    let childAttributes = [kAXChildrenAttribute, kAXContentsAttribute]
    childAttributes.forEach { attributeName in
        let children = attribute(element, attributeName) as? [AXUIElement] ?? []
        children.forEach { walk($0, depth: depth + 1) }
    }
}

windows.forEach { walk($0, depth: 0) }

let requirements = [
    Requirement(label: "截图标注画布", role: kAXGroupRole, requiresValue: true, requiresPressAction: false),
    Requirement(label: "模糊强度", role: kAXSliderRole, requiresValue: true, requiresPressAction: false),
    Requirement(label: "画布留白", role: kAXSliderRole, requiresValue: true, requiresPressAction: false),
    Requirement(label: "画布圆角", role: kAXSliderRole, requiresValue: true, requiresPressAction: false),
    Requirement(label: "复制", role: kAXButtonRole, requiresValue: false, requiresPressAction: true),
    Requirement(label: "完成并复制", role: kAXButtonRole, requiresValue: false, requiresPressAction: true),
    Requirement(label: "留白", role: kAXSliderRole, requiresValue: true, requiresPressAction: false),
    Requirement(label: "推近倍率", role: kAXSliderRole, requiresValue: true, requiresPressAction: false),
    Requirement(label: "预览播放位置", role: kAXSliderRole, requiresValue: true, requiresPressAction: false),
    Requirement(label: "关闭视频编辑器", role: kAXButtonRole, requiresValue: false, requiresPressAction: true)
]

let checks = requirements.map { requirement in
    let match = elements.first {
        $0.label == requirement.label
            && $0.role == requirement.role
            && (!requirement.requiresValue || !$0.value.isEmpty)
            && (!requirement.requiresPressAction || $0.actions.contains(kAXPressAction))
    }
    return Check(requirement: requirement, passed: match != nil, matched: match)
}
let accessibilityTrusted = AXIsProcessTrusted()
let passed = accessibilityTrusted && windows.count >= 2 && checks.allSatisfy(\.passed)
let report = Report(
    result: passed ? "passed" : "failed",
    accessibilityTrusted: accessibilityTrusted,
    processIdentifier: pid,
    windowCount: windows.count,
    visitedElementCount: visited,
    checks: checks
)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.dateEncodingStrategy = .iso8601
let outputURL = URL(fileURLWithPath: reportPath).standardizedFileURL
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try encoder.encode(report).write(to: outputURL, options: .atomic)
exit(passed ? 0 : 1)
