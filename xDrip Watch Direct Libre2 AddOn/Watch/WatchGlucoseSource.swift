import Foundation

/// Identifies the transport that supplied the currently displayed glucose history.
enum WatchGlucoseSource {
    case phoneRelay
    case directLibre2

    var title: String {
        switch self {
        case .phoneRelay:
            return Texts_DirectLibre.phoneRelay
        case .directLibre2:
            return Texts_DirectLibre.directLibre
        }
    }
}
