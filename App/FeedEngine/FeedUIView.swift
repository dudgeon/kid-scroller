import UIKit
import SameAgeCore

/// One photo slot in a ribbon. Pooled and recycled; never allocated during a scroll.
final class RibbonCellView: UIView {
    private let label = UILabel()
    private let glyph = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.masksToBounds = true

        glyph.font = .systemFont(ofSize: 22)
        glyph.textAlignment = .center
        glyph.textColor = .white
        addSubview(glyph)

        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 5
        label.layer.masksToBounds = true
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func layoutSubviews() {
        super.layoutSubviews()
        glyph.frame = bounds
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 6, y: bounds.height - size.height - 10,
                             width: size.width + 12, height: size.height + 4)
    }

    /// Placeholder rendering until the PhotoKit image pipeline is wired in: a stable
    /// per-item colour plus the age tag, so the physics can be verified visually.
    func configure(with item: FeedItem) {
        var hash = 5381
        for byte in item.assetIdentifier.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        let hue = CGFloat(abs(hash) % 360) / 360
        let tint: CGFloat = item.kid == .a ? 0.09 : 0.58   // warm for A, cool for B
        backgroundColor = UIColor(hue: (hue * 0.12 + tint).truncatingRemainder(dividingBy: 1),
                                  saturation: 0.62, brightness: 0.72, alpha: 1)
        glyph.text = item.kind == .video ? "▶" : (item.kind == .livePhoto ? "◉" : "")
        label.text = "  \(AgeFormatter.short(months: item.ageMonths))\(item.isFavorite ? " ♥" : "")  "
        setNeedsLayout()
    }
}

/// One kid's ribbon. Positions a small pool of cells against the shared age axis.
final class RibbonColumnView: UIView {
    private var mapping: RibbonMapping = .empty
    private var live: [String: RibbonCellView] = [:]
    private var free: [RibbonCellView] = []
    private var ghosted = false

    func setMapping(_ mapping: RibbonMapping) {
        self.mapping = mapping
        for (_, cell) in live { recycle(cell) }
        live.removeAll()
    }

    private func recycle(_ cell: RibbonCellView) {
        cell.removeFromSuperview()
        if free.count < 40 { free.append(cell) }
    }

    private func dequeue() -> RibbonCellView {
        if let cell = free.popLast() { return cell }
        return RibbonCellView(frame: .zero)
    }

    /// Positions every cell intersecting the viewport at `age`, recycling the rest.
    func update(age: Double, viewportHeight: Double) {
        let (range, columnOffset) = mapping.visibleRange(atAge: age, viewportHeight: viewportHeight)
        let readingLine = viewportHeight * RibbonMetrics.readingLineFraction

        var stillVisible = Set<String>()
        stillVisible.reserveCapacity(range.count)

        for index in range {
            let placed = mapping.placed[index]
            let id = placed.item.id
            stillVisible.insert(id)

            let cell: RibbonCellView
            if let existing = live[id] {
                cell = existing
            } else {
                cell = dequeue()
                cell.configure(with: placed.item)
                addSubview(cell)
                live[id] = cell
            }
            cell.frame = CGRect(x: 0,
                                y: readingLine + (placed.top - columnOffset),
                                width: bounds.width,
                                height: placed.height)
        }

        for (id, cell) in live where !stillVisible.contains(id) {
            recycle(cell)
            live.removeValue(forKey: id)
        }

        // D3 / R3: when this kid has no photos near the current age, the held photo
        // ghosts so it reads as "waiting" rather than as fresh content.
        let shouldGhost = mapping.isSparse(atAge: age)
        if shouldGhost != ghosted {
            ghosted = shouldGhost
            UIView.animate(withDuration: 0.15) { self.alpha = shouldGhost ? 0.38 : 1.0 }
        }
    }
}

/// The feed: a transparent `UIScrollView` drives the physics, two ribbon columns render.
///
/// Under D1 (constant content speed) the combined offset `s` is *linear* in finger travel,
/// so a stock scroll view whose `contentSize` is the total content extent gives native
/// momentum, deceleration and rubber-banding on `s` for free. Age is then a pure function
/// of the scroll offset. Two stock scroll views could not do this: they would need to share
/// one gesture while advancing at different, nonlinearly-related rates.
final class FeedUIView: UIView, UIScrollViewDelegate {

    struct Metrics {
        static let railWidth: CGFloat = 30
        static let outerPadding: CGFloat = 6
        /// D4: gap only — no divider rule between the ribbons.
        static let columnGap: CGFloat = 10
    }

    private let scrollView = UIScrollView()
    private let sizingView = UIView()
    private let columnA = RibbonColumnView()
    private let columnB = RibbonColumnView()

    private var combined: CombinedMapping?
    private var itemsA: [FeedItem] = []
    private var itemsB: [FeedItem] = []
    private var axisMax: Double = 84
    private var railOnLeft = true
    private var isProgrammaticScroll = false
    private var lastLaidOutWidth: CGFloat = 0
    /// Identifies the current content so `configure` can no-op. SwiftUI calls
    /// `updateUIView` on every age tick; without this the mappings would be rebuilt at
    /// scroll frequency, which is both wasteful and visibly glitchy.
    private var contentVersion: Int?
    /// An age requested before the mappings existed; applied once they do.
    private var pendingAge: Double?

    /// Reports the current age as the feed moves. Drives the rail and the age pill.
    var onAgeChange: ((Double) -> Void)?
    /// Fires once the user has stopped scrolling *and* lifted their finger (R15).
    var onSettled: ((Double) -> Void)?

    private var settleWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        addSubview(columnA)
        addSubview(columnB)

        scrollView.delegate = self
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(sizingView)
        addSubview(scrollView)   // on top: it owns the pan gesture
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // MARK: - Configuration

    func configure(
        itemsA: [FeedItem], itemsB: [FeedItem],
        axisMax: Double, railOnLeft: Bool, version: Int
    ) {
        guard version != contentVersion else { return }
        contentVersion = version

        self.itemsA = itemsA
        self.itemsB = itemsB
        self.axisMax = max(axisMax, 1)
        self.railOnLeft = railOnLeft
        lastLaidOutWidth = 0          // force a rebuild on next layout pass
        setNeedsLayout()
    }

    /// Rebuilds both layouts and the combined mapping, preserving the current age.
    private func rebuildMappings(columnWidth: CGFloat) {
        // A filter change must not move the user in time — hold the current age across
        // the rebuild (R22).
        let preservedAge = pendingAge ?? currentAge
        pendingAge = nil
        let a = RibbonMapping(placed: RibbonLayout.build(items: itemsA, columnWidth: Double(columnWidth)))
        let b = RibbonMapping(placed: RibbonLayout.build(items: itemsB, columnWidth: Double(columnWidth)))
        let mapping = CombinedMapping(a: a, b: b, axisMax: axisMax)
        combined = mapping

        columnA.setMapping(a)
        columnB.setMapping(b)

        scrollView.contentSize = CGSize(width: bounds.width,
                                        height: CGFloat(mapping.sMax - mapping.sMin) + bounds.height)
        setAge(preservedAge, animated: false)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        scrollView.frame = bounds
        sizingView.frame = CGRect(origin: .zero, size: scrollView.contentSize)

        let usable = bounds.width - Metrics.railWidth - Metrics.outerPadding * 2 - Metrics.columnGap
        let columnWidth = max(usable / 2, 1)
        let leadingInset = (railOnLeft ? Metrics.railWidth : 0) + Metrics.outerPadding

        columnA.frame = CGRect(x: leadingInset, y: 0, width: columnWidth, height: bounds.height)
        columnB.frame = CGRect(x: leadingInset + columnWidth + Metrics.columnGap, y: 0,
                               width: columnWidth, height: bounds.height)

        if abs(columnWidth - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = columnWidth
            rebuildMappings(columnWidth: columnWidth)
        } else {
            refresh()
        }
    }

    // MARK: - Age <-> scroll offset

    var currentAge: Double {
        guard let combined else { return 0 }
        return combined.age(atCombinedOffset: combined.sMin + Double(scrollView.contentOffset.y))
    }

    func setAge(_ age: Double, animated: Bool) {
        guard let combined else {
            pendingAge = age          // mappings not built yet; apply on first layout
            return
        }
        let clamped = min(max(age, 0), axisMax)
        let y = CGFloat(combined.offset(atAge: clamped) - combined.sMin)
        let maxY = max(scrollView.contentSize.height - bounds.height, 0)
        let target = CGPoint(x: 0, y: min(max(y, 0), maxY))

        isProgrammaticScroll = true
        scrollView.setContentOffset(target, animated: animated)
        isProgrammaticScroll = false
        refresh()
    }

    private func refresh() {
        let age = currentAge
        columnA.update(age: age, viewportHeight: Double(bounds.height))
        columnB.update(age: age, viewportHeight: Double(bounds.height))
        onAgeChange?(age)
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        refresh()
        if !isProgrammaticScroll { cancelSettle() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleSettle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { scheduleSettle() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { scheduleSettle() }

    /// R15: videos autoplay only after scrolling stops *and* the finger has been lifted
    /// for more than a second.
    private func scheduleSettle() {
        cancelSettle()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.scrollView.isTracking, !self.scrollView.isDecelerating else { return }
            self.onSettled?(self.currentAge)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func cancelSettle() {
        settleWork?.cancel()
        settleWork = nil
    }
}
