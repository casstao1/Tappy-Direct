import Foundation

enum SoundCategory: String, CaseIterable, Identifiable {
    case standard = "default"
    case space = "space"
    case returnKey = "return"
    case delete = "delete"
    case modifier = "modifier"

    var id: String { rawValue }

    var folderName: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return "Default"
        case .space:
            return "Space"
        case .returnKey:
            return "Return"
        case .delete:
            return "Delete"
        case .modifier:
            return "Modifier"
        }
    }

    var guidance: String {
        switch self {
        case .standard:
            return "Fallback for most keys."
        case .space:
            return "Used for the space bar."
        case .returnKey:
            return "Used for return and enter."
        case .delete:
            return "Used for delete and forward delete."
        case .modifier:
            return "Used for shift, command, option, control, caps lock, and fn."
        }
    }
}
