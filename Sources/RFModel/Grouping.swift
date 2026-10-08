import Foundation

/// One group of a grouped arrangement. Groups are ordered by `rank`, then `title`.
struct GroupBucket: Hashable, Comparable {
    let rank: Int
    let title: String

    static func < (a: GroupBucket, b: GroupBucket) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    static let unknown = GroupBucket(rank: .max, title: "Unknown")

    static func of(_ item: FileItem, by key: GroupKey, now: Date, calendar: Calendar) -> GroupBucket {
        switch key {
        case .kind:
            return GroupBucket(rank: 0, title: KindNames.name(for: item))
        case .dateModified:
            return item.modified.map { dateBucket($0, now: now, calendar: calendar) } ?? .unknown
        case .dateCreated:
            return item.created.map { dateBucket($0, now: now, calendar: calendar) } ?? .unknown
        case .dateAdded:
            return item.added.map { dateBucket($0, now: now, calendar: calendar) } ?? .unknown
        case .size:
            guard !item.isNavigableFolder, let size = item.size else { return GroupBucket(rank: 100, title: "Folders") }
            return sizeBucket(size)
        }
    }

    /// Finder-style relative date groups, newest first.
    static func dateBucket(_ date: Date, now: Date, calendar: Calendar) -> GroupBucket {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        if days <= 0 { return GroupBucket(rank: 0, title: "Today") }
        if days == 1 { return GroupBucket(rank: 1, title: "Yesterday") }
        if days <= 7 { return GroupBucket(rank: 2, title: "Previous 7 Days") }
        if days <= 30 { return GroupBucket(rank: 3, title: "Previous 30 Days") }
        let year = calendar.component(.year, from: date)
        let thisYear = calendar.component(.year, from: now)
        if year == thisYear {
            let month = calendar.component(.month, from: date)
            return GroupBucket(rank: 100 + (12 - month), title: calendar.standaloneMonthSymbols[month - 1])
        }
        return GroupBucket(rank: 1000 + (thisYear - year), title: String(year))
    }

    static func sizeBucket(_ size: Int64) -> GroupBucket {
        let kb: Int64 = 1000, mb = kb * 1000, gb = mb * 1000
        switch size {
        case gb...: return GroupBucket(rank: 1, title: "Larger than 1 GB")
        case (100 * mb)...: return GroupBucket(rank: 2, title: "100 MB to 1 GB")
        case (10 * mb)...: return GroupBucket(rank: 3, title: "10 MB to 100 MB")
        case mb...: return GroupBucket(rank: 4, title: "1 MB to 10 MB")
        case (100 * kb)...: return GroupBucket(rank: 5, title: "100 KB to 1 MB")
        case 1...: return GroupBucket(rank: 6, title: "Smaller than 100 KB")
        default: return GroupBucket(rank: 7, title: "Zero bytes")
        }
    }
}
