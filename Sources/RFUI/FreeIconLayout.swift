import AppKit

/// Icon view with Sort By None (DESIGN.md §3.3, §4.2): every item at its own position. Frames are
/// computed by `FreeArrangement` and handed in; this only reports them to the collection view.
final class FreeIconLayout: NSCollectionViewLayout {
    var frames: [NSRect] = []
    var minimumSize = NSSize.zero

    override var collectionViewContentSize: NSSize {
        let maxX = frames.map(\.maxX).max() ?? 0, maxY = frames.map(\.maxY).max() ?? 0
        return NSSize(width: max(minimumSize.width, maxX + 14), height: max(minimumSize.height, maxY + 14))
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        frames.enumerated().compactMap { i, frame in
            guard frame.intersects(rect) else { return nil }
            return attributes(i, frame)
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, frames.indices.contains(indexPath.item) else { return nil }
        return attributes(indexPath.item, frames[indexPath.item])
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }

    private func attributes(_ i: Int, _ frame: NSRect) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
        a.frame = frame
        return a
    }
}

/// Where each icon goes: its saved position, or the first free grid cell (row by row, in the
/// current order) for items that don't have one yet.
struct FreeArrangement {
    var cellSize: NSSize
    var spacing: CGFloat
    var width: CGFloat
    var inset = NSPoint(x: 14, y: 10)
    /// The desktop fills columns from the top right, like Finder; windows fill rows from the top left.
    var height: CGFloat = 0
    var fromRight = false

    var pitch: NSSize { NSSize(width: cellSize.width + spacing, height: cellSize.height + spacing) }
    var columns: Int { max(1, Int((width - inset.x * 2 + spacing) / pitch.width)) }
    var rows: Int { max(1, Int((height - inset.y * 2 + spacing) / pitch.height)) }

    func cellOrigin(_ index: Int) -> NSPoint {
        if fromRight {
            return NSPoint(x: width - inset.x - cellSize.width - CGFloat(index / rows) * pitch.width,
                           y: inset.y + CGFloat(index % rows) * pitch.height)
        }
        return NSPoint(x: inset.x + CGFloat(index % columns) * pitch.width, y: inset.y + CGFloat(index / columns) * pitch.height)
    }

    /// Frames for `names` (in display order), using `saved` where present. Linear: saved frames
    /// mark the grid cells they overlap, and new items take the free cells in order.
    func frames(for names: [String], saved: [String: CGPoint]) -> [NSRect] {
        var occupied = Set<Int>()
        let cols = columns
        for name in names {
            guard let p = saved[name] else { continue }
            if fromRight {
                occupied.insert(cell(of: p))
                continue
            }
            let r = NSRect(origin: p, size: cellSize).insetBy(dx: 4, dy: 4)
            let c0 = max(0, Int(floor((r.minX - inset.x) / pitch.width))), c1 = Int(floor((r.maxX - inset.x) / pitch.width))
            let r0 = max(0, Int(floor((r.minY - inset.y) / pitch.height))), r1 = Int(floor((r.maxY - inset.y) / pitch.height))
            guard c0 < cols, c1 >= 0, r1 >= 0 else { continue }
            for row in r0...max(r0, r1) {
                for col in c0...min(cols - 1, max(c0, c1)) { occupied.insert(row * cols + col) }
            }
        }
        var next = 0
        return names.map { name in
            if let p = saved[name] { return NSRect(origin: p, size: cellSize) }
            while occupied.contains(next) { next += 1 }
            occupied.insert(next)
            return NSRect(origin: cellOrigin(next), size: cellSize)
        }
    }

    /// Clean Up: each item to the nearest free grid cell, top-left items first.
    func snapped(_ positions: [String: CGPoint]) -> [String: CGPoint] {
        var used = Set<Int>()
        var out: [String: CGPoint] = [:]
        let ordered = positions.sorted { ($0.value.y, $0.value.x, $0.key) < ($1.value.y, $1.value.x, $1.key) }
        for (name, p) in ordered {
            let base = cell(of: p)
            var step = 0
            var chosen: Int?
            while chosen == nil {
                chosen = [base + step, base - step].first { $0 >= 0 && !used.contains($0) }
                step += 1
            }
            used.insert(chosen!)
            out[name] = cellOrigin(chosen!)
        }
        return out
    }

    /// Snap to Grid while moving: each moved item to the nearest grid cell that no other item
    /// (moved or not) occupies.
    func snapped(_ moved: [String: CGPoint], others: [String: CGPoint]) -> [String: CGPoint] {
        var used = Set(others.values.map { cell(of: $0) })
        var out: [String: CGPoint] = [:]
        for (name, p) in moved.sorted(by: { ($0.value.y, $0.value.x) < ($1.value.y, $1.value.x) }) {
            let base = cell(of: p)
            var step = 0
            var chosen: Int?
            while chosen == nil {
                chosen = [base + step, base - step].first { $0 >= 0 && !used.contains($0) }
                step += 1
            }
            used.insert(chosen!)
            out[name] = cellOrigin(chosen!)
        }
        return out
    }

    private func cell(of p: CGPoint) -> Int {
        if fromRight {
            let col = max(0, Int(((width - inset.x - cellSize.width - p.x) / pitch.width).rounded()))
            let row = min(rows - 1, max(0, Int(((p.y - inset.y) / pitch.height).rounded())))
            return col * rows + row
        }
        let col = min(columns - 1, max(0, Int(((p.x - inset.x) / pitch.width).rounded())))
        let row = max(0, Int(((p.y - inset.y) / pitch.height).rounded()))
        return row * columns + col
    }

    /// Where dropped items go: stacked down and right from the drop point.
    func dropPositions(_ names: [String], at point: NSPoint) -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        for (i, name) in names.enumerated() {
            out[name] = CGPoint(x: max(0, point.x - cellSize.width / 2 + CGFloat(i) * 12),
                                y: max(0, point.y - cellSize.height / 2 + CGFloat(i) * 12))
        }
        return out
    }
}

extension FreeIconLayout {
    /// Drops land on the folder under the pointer, or anywhere in empty space.
    override func layoutAttributesForDropTarget(at point: NSPoint) -> NSCollectionViewLayoutAttributes? {
        if let i = frames.firstIndex(where: { $0.contains(point) }) {
            let a = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: i, section: 0))
            a.frame = frames[i]
            return a
        }
        let gap = NSCollectionViewLayoutAttributes(forInterItemGapBefore: IndexPath(item: frames.count, section: 0))
        gap.frame = NSRect(origin: point, size: .zero)
        return gap
    }
}
