import Foundation

/// A Finder tag (DESIGN.md §5.8). Stored in the `com.apple.metadata:_kMDItemUserTags` xattr as
/// "Name\n<color>" strings.
public struct Tag: Hashable, Codable, Sendable {
    public var name: String
    public var color: TagColor

    public init(_ name: String, color: TagColor = .none) {
        self.name = name
        self.color = color
    }

    /// Finder's color tags, in Finder's menu order.
    public static let standard: [Tag] = [
        Tag("Red", color: .red), Tag("Orange", color: .orange), Tag("Yellow", color: .yellow), Tag("Green", color: .green),
        Tag("Blue", color: .blue), Tag("Purple", color: .purple), Tag("Gray", color: .gray),
    ]

    /// The color a tag name has by default (for the standard names), else none.
    public static func defaultColor(for name: String) -> TagColor {
        standard.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.color ?? .none
    }
}

/// Finder's label color indices.
public enum TagColor: Int, Codable, Sendable, CaseIterable {
    case none = 0, gray, green, purple, blue, yellow, red, orange
}
