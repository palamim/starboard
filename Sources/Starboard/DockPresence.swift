import Cocoa

enum DockPresence {
    case revealed(tray: NSRect, host: NSScreen)
    case concealed(tray: NSRect, host: NSScreen)
    case untracked(host: NSScreen)

    var host: NSScreen {
        switch self {
        case .revealed(_, let host), .concealed(_, let host), .untracked(let host):
            return host
        }
    }

    var isUntracked: Bool {
        if case .untracked = self { return true }
        return false
    }

    var summary: String {
        switch self {
        case .revealed(let tray, let host):
            return "revealed tray=\(tray) host=\(host.frame)"
        case .concealed(let tray, let host):
            return "concealed tray=\(tray) host=\(host.frame)"
        case .untracked(let host):
            return "untracked host=\(host.frame)"
        }
    }
}
