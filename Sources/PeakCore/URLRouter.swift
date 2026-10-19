import Foundation

/// forceiq-peak:// actions (Raycast script commands and anything else on this Mac).
/// Strict: scheme forceiq-peak, the action is the host, only the listed query keys, unknown actions ignored.
/// Nothing here ever sends: `ask` only opens the ask field prefilled.
public enum PeakURLAction: Equatable, Sendable {
    case toggle, show, hide, expand, collapse
    case ask(String?)
    case switchApp(String)
    case display(uuid: String, on: Bool)
    case threePOModel(ModelPick)          // forceiq-peak://3po?model=auto|haiku|sonnet|opus (picks the 3PO model; never sends)

    /// The only thing ever logged about a URL: the action name (never the query).
    public var name: String {
        switch self {
        case .toggle: return "toggle"
        case .show: return "show"
        case .hide: return "hide"
        case .expand: return "expand"
        case .collapse: return "collapse"
        case .ask: return "ask"
        case .switchApp: return "switch"
        case .display: return "display"
        case .threePOModel: return "3po"
        }
    }
}

public enum PeakURLRouter {
    public static let scheme = "forceiq-peak"
    public static let maxAskLength = 500
    static let uuidRx = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#

    public static func parse(_ raw: String, allowedBundleIDs: Set<String>) -> PeakURLAction? {
        guard raw.count <= 2048, let c = URLComponents(string: raw), c.scheme?.lowercased() == scheme,
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil else { return nil }
        let path = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.isEmpty, let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] {
            guard q[item.name] == nil else { return nil }          // a repeated key is ambiguous: reject
            q[item.name] = item.value ?? ""
        }
        func only(_ keys: Set<String>) -> Bool { Set(q.keys).isSubset(of: keys) }
        switch host {
        case "toggle", "show", "hide", "expand", "collapse":
            guard q.isEmpty else { return nil }
            return ["toggle": .toggle, "show": .show, "hide": .hide, "expand": .expand, "collapse": .collapse][host]
        case "ask":
            guard only(["q"]) else { return nil }
            let text = (q["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= maxAskLength, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return .ask(text.isEmpty ? nil : text)
        case "switch":
            guard only(["app"]), let app = q["app"], allowedBundleIDs.contains(app) else { return nil }
            return .switchApp(app)
        case "display":
            guard only(["id", "state"]), let id = q["id"], id.range(of: uuidRx, options: .regularExpression) != nil,
                  let st = q["state"]?.lowercased(), st == "on" || st == "off" else { return nil }
            return .display(uuid: id.uppercased(), on: st == "on")
        case "3po":
            guard only(["model"]), let m = q["model"]?.lowercased(), let pick = ModelPick(rawValue: m) else { return nil }
            return .threePOModel(pick)
        default:
            return nil
        }
    }
}
