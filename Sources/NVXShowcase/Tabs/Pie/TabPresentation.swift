import AppKit

/// Application tabs keep their titles. Address editing is an explicit opt-in.
enum CompactTabLabelMode: Equatable {
    case fixed
    case address
}

struct CompactTabHoverContent: Equatable {
    var title: String
    var subtitle: String? = nil
    var detail: String? = nil
}

struct CompactTabHoverConfiguration: Equatable {
    /// Seconds of pointer rest before showing the card.
    var delay: TimeInterval = 0.65
    var maximumWidth: CGFloat = 280
}
