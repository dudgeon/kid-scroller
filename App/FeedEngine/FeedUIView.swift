import UIKit
import Photos
import AVFoundation
import SameAgeCore

/// One photo slot in a ribbon. Pooled and recycled; never allocated during a scroll.
final class RibbonCellView: UIView {
    private let imageView = UIImageView()
    private let label = UILabel()
    private let glyph = UILabel()

    /// In-flight PhotoKit request, cancelled if the cell is recycled before it lands.
    private var requestID: PHImageRequestID?
    /// Guards against a slow request resolving into a cell that has since been reused.
    private var currentItemID: String?
    private var currentItem: FeedItem?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: NSObjectProtocol?
    /// Whether this cell has already been re-fetched at full quality since it was configured.
    private var isUpgraded = false

    var isVideo: Bool { currentItem?.kind == .video }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.masksToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)

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
        imageView.frame = bounds
        playerLayer?.frame = bounds
        glyph.frame = bounds
        let size = label.intrinsicContentSize
        label.frame = CGRect(x: 6, y: bounds.height - size.height - 10,
                             width: size.width + 12, height: size.height + 4)
    }

    func configure(with item: FeedItem, targetSize: CGSize) {
        currentItemID = item.id
        currentItem = item

        // A stable per-item colour shows immediately and stays visible behind an image
        // that is still loading — or permanently, for synthetic fixtures with no asset.
        var hash = 5381
        for byte in item.assetIdentifier.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        let hue = CGFloat(abs(hash) % 360) / 360
        let tint: CGFloat = item.kid == .a ? 0.09 : 0.58   // warm for A, cool for B
        backgroundColor = UIColor(hue: (hue * 0.12 + tint).truncatingRemainder(dividingBy: 1),
                                  saturation: 0.62, brightness: 0.72, alpha: 1)

        glyph.text = item.kind == .video ? "▶" : (item.kind == .livePhoto ? "◉" : "")
        label.text = "  \(AgeFormatter.short(months: item.ageMonths))\(item.isFavorite ? " ♥" : "")  "
        imageView.image = nil

        let scale = UIScreen.main.scale
        let pixelSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        requestID = ThumbnailProvider.shared.request(
            identifier: item.assetIdentifier, targetSize: pixelSize
        ) { [weak self] image, _ in
            // The cell may have been recycled onto a different item while this was in
            // flight; dropping the result is what stops photos landing in wrong slots.
            guard let self, self.currentItemID == item.id, let image else { return }
            self.imageView.image = image
        }
        setNeedsLayout()
    }

    /// Re-fetches at full quality once the feed has stopped moving.
    ///
    /// The scrolling pass deliberately asks only for fast, cache-resident frames — that is
    /// what keeps the feed smooth — so the photo on screen may be soft. This sharpens it
    /// at the one moment the viewer is actually looking at it, and is also the first point
    /// at which an iCloud fetch is acceptable.
    func upgradeImage() {
        guard !isUpgraded, let item = currentItem, bounds.width > 0 else { return }
        isUpgraded = true

        let scale = UIScreen.main.scale
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        ThumbnailProvider.shared.request(
            identifier: item.assetIdentifier, targetSize: pixelSize, quality: .high
        ) { [weak self] image, isDegraded in
            // Only take the sharp frame; the degraded one is what we already have.
            guard let self, self.currentItemID == item.id, let image, !isDegraded else { return }
            self.imageView.image = image
        }
    }

    /// R15 — muted, looping playback in place. Streams from the asset rather than
    /// downloading a copy, so this adds no local storage.
    func startVideo() {
        guard isVideo, playerLayer == nil, let item = currentItem else { return }
        Task { @MainActor in
            guard let playerItem = await ThumbnailProvider.shared
                .requestPlayerItem(identifier: item.assetIdentifier) else { return }
            // The cell may have been recycled or scrolling resumed while this loaded.
            guard currentItemID == item.id, playerLayer == nil else { return }

            let player = AVPlayer(playerItem: playerItem)
            player.isMuted = true                      // R15: muted in the feed
            let layer = AVPlayerLayer(player: player)
            layer.frame = bounds
            layer.videoGravity = .resizeAspectFill
            self.layer.insertSublayer(layer, above: imageView.layer)
            playerLayer = layer

            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero)
                player?.play()
            }
            player.play()
            glyph.isHidden = true                      // hide the ▶ badge while playing
        }
    }

    func stopVideo() {
        playerLayer?.player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = nil
        glyph.isHidden = false
    }

    /// Cancels any in-flight request and clears state before the cell goes back in the pool.
    func prepareForReuse() {
        stopVideo()
        if let requestID { ThumbnailProvider.shared.cancel(requestID) }
        requestID = nil
        currentItemID = nil
        currentItem = nil
        isUpgraded = false
        imageView.image = nil
    }
}

/// One kid's ribbon. Positions a small pool of cells against the shared age axis.
final class RibbonColumnView: UIView {
    private var mapping: RibbonMapping = .empty
    private var live: [String: RibbonCellView] = [:]
    private var liveItems: [String: FeedItem] = [:]
    private var free: [RibbonCellView] = []
    private var ghosted = false
    /// Assets currently preheated in PHCachingImageManager, with the pixel size each was
    /// cached at (stop-caching must pass the same size to actually release it).
    private var preheated: [String: CGSize] = [:]

    /// The item under a point in this column's coordinate space, if any (R17).
    func item(at point: CGPoint) -> FeedItem? {
        for (id, cell) in live where cell.frame.contains(point) { return liveItems[id] }
        return nil
    }

    /// Plays the topmost mostly-visible video in this column, at most one at a time (R15).
    ///
    /// "Mostly" rather than "fully": a tall video can never be entirely on screen, so a
    /// strict test silently meant such clips never played at all. Requiring 60% visible
    /// still excludes anything half off the edge, which would just be noise.
    func playTopmostVideo(viewportHeight: CGFloat) {
        stopVideos()
        let candidates = live.values.filter { cell in
            guard cell.isVideo, cell.frame.height > 0 else { return false }
            let visible = min(cell.frame.maxY, viewportHeight) - max(cell.frame.minY, 0)
            return visible / cell.frame.height >= 0.6
        }
        candidates.min { $0.frame.minY < $1.frame.minY }?.startVideo()
    }

    /// Sharpens every on-screen photo once the feed has stopped moving.
    func upgradeVisibleImages() {
        for cell in live.values { cell.upgradeImage() }
    }

    func stopVideos() {
        for cell in live.values { cell.stopVideo() }
    }

    func setMapping(_ mapping: RibbonMapping) {
        self.mapping = mapping
        for (_, cell) in live { recycle(cell) }
        live.removeAll()
        liveItems.removeAll()
        // Release this column's warm cache without touching the sibling column's.
        for (id, size) in preheated {
            ThumbnailProvider.shared.stopCaching(identifiers: [id], targetSize: size)
        }
        preheated.removeAll()
    }

    private func recycle(_ cell: RibbonCellView) {
        cell.prepareForReuse()          // cancels any in-flight PhotoKit request
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
                cell.configure(with: placed.item,
                               targetSize: CGSize(width: bounds.width, height: placed.height))
                addSubview(cell)
                live[id] = cell
                liveItems[id] = placed.item
            }
            cell.frame = CGRect(x: 0,
                                y: readingLine + (placed.top - columnOffset),
                                width: bounds.width,
                                height: placed.height)
        }

        for (id, cell) in live where !stillVisible.contains(id) {
            recycle(cell)
            live.removeValue(forKey: id)
            liveItems.removeValue(forKey: id)
        }

        // D3 / R3: when this kid has no photos near the current age, the held photo
        // ghosts so it reads as "waiting" rather than as fresh content.
        let shouldGhost = mapping.isSparse(atAge: age)
        if shouldGhost != ghosted {
            ghosted = shouldGhost
            UIView.animate(withDuration: 0.15) { self.alpha = shouldGhost ? 0.38 : 1.0 }
        }

        updatePreheat(around: range)
    }

    /// Keeps PHCachingImageManager warm for a window either side of the viewport, so
    /// scrolling lands on already-decoded thumbnails instead of requesting them mid-frame.
    /// This is the single biggest scroll-smoothness lever PhotoKit offers — the manager
    /// existed from day one but nothing ever called it.
    private func updatePreheat(around range: Range<Int>) {
        guard bounds.width > 0, !mapping.placed.isEmpty else { return }
        let scale = UIScreen.main.scale
        let margin = 14   // items either side — roughly one extra screen each way

        let lo = max(0, range.lowerBound - margin)
        let hi = min(mapping.placed.count, range.upperBound + margin)
        guard lo < hi else { return }

        var desired: [String: CGSize] = [:]
        desired.reserveCapacity(hi - lo)
        for index in lo..<hi {
            let placed = mapping.placed[index]
            desired[placed.item.assetIdentifier] = CGSize(width: bounds.width * scale,
                                                          height: placed.height * scale)
        }

        // Only the diff hits PhotoKit; a frame where the window hasn't moved does nothing.
        for (id, size) in desired where preheated[id] == nil {
            ThumbnailProvider.shared.startCaching(identifiers: [id], targetSize: size)
        }
        for (id, size) in preheated where desired[id] == nil {
            ThumbnailProvider.shared.stopCaching(identifiers: [id], targetSize: size)
        }
        preheated = desired
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
    /// Tapping a photo opens it fullscreen (R17).
    var onSelect: ((FeedItem) -> Void)?
    /// Long-pressing a photo offers to hide it from the app.
    var onLongPress: ((FeedItem) -> Void)?
    /// Scrolling up (towards newborn) reveals the top chrome; scrolling down hides it.
    var onChromeVisibilityChange: ((Bool) -> Void)?

    private var chromeVisible = true
    private var lastOffsetY: CGFloat = 0

    private var settleWork: DispatchWorkItem?
    private var videosPlaying = false

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

        // The scroll view sits above the columns, so the tap has to be handled here and
        // hit-tested down into whichever column was touched.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scrollView.addGestureRecognizer(tap)

        // The scroll view's pan cancels an in-flight long press as soon as the finger
        // moves, so this only fires on a genuinely stationary press.
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.45
        scrollView.addGestureRecognizer(longPress)
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let point = recognizer.location(in: self)
        for column in [columnA, columnB] {
            if let item = column.item(at: convert(point, to: column)) {
                onLongPress?(item)
                return
            }
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        for column in [columnA, columnB] {
            if let item = column.item(at: convert(point, to: column)) {
                // Hand off cleanly to fullscreen: tear down any in-feed playback and drop
                // the pending settle, or a video starts behind the fullscreen view and is
                // found playing when it's dismissed.
                cancelSettle()
                stopVideos()
                onSelect?(item)
                return
            }
        }
    }

    /// Called when the feed goes off screen (fullscreen, sheets) so nothing plays unseen.
    func suspendPlayback() {
        cancelSettle()
        stopVideos()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    // MARK: - Configuration

    func configure(
        itemsA: [FeedItem], itemsB: [FeedItem],
        axisMax: Double, railOnLeft: Bool, version: Int
    ) {
        // The version is the intended signal, but a wrong version silently strands the
        // feed on stale data with no error anywhere — which is exactly how build 0.1 (1)
        // shipped a permanently black feed. Comparing counts as well costs nothing and
        // turns that failure mode from silent-wrong into self-healing.
        let contentChanged = itemsA.count != self.itemsA.count || itemsB.count != self.itemsB.count
        guard version != contentVersion || contentChanged else { return }
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

        // Settling is not only something a finger-scroll produces. The first render, a
        // rail scrub and a typed age jump all leave the feed stationary too, and each
        // should sharpen the photos and start any video. Without this, playback never
        // began until you had scrolled and stopped at least once.
        scheduleSettle()
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
        // Any movement tears playback down immediately (R15).
        if videosPlaying { stopVideos() }
        // Track the offset on EVERY fire, including programmatic jumps and layout-induced
        // ones — otherwise the first user scroll after a setAge() compares against a stale
        // origin, reads as a huge "downward scroll", and hides the chrome at launch.
        let y = scrollView.contentOffset.y
        let delta = y - lastOffsetY
        lastOffsetY = y

        // Browser-style chrome: swiping back towards newborn (or rubber-banding at the
        // top) reveals the names bar; scrolling deeper hides it. Only finger-driven
        // movement counts — layout passes and programmatic jumps say nothing about intent.
        let userDriven = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
        if userDriven {
            if delta < -6 || y <= 0 {
                setChromeVisible(true)
            } else if delta > 6 {
                setChromeVisible(false)
            }
        }

        if !isProgrammaticScroll { cancelSettle() }
    }

    private func setChromeVisible(_ visible: Bool) {
        guard visible != chromeVisible else { return }
        chromeVisible = visible
        onChromeVisibilityChange?(visible)
    }

    private func stopVideos() {
        columnA.stopVideos()
        columnB.stopVideos()
        videosPlaying = false
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
            // Both conditions matter: scrolling has stopped AND the finger is off the glass.
            guard let self, !self.scrollView.isTracking, !self.scrollView.isDecelerating else { return }
            // Settling is the moment the viewer is actually looking: sharpen the photos
            // and start the topmost video.
            self.columnA.upgradeVisibleImages()
            self.columnB.upgradeVisibleImages()
            self.columnA.playTopmostVideo(viewportHeight: self.bounds.height)
            self.columnB.playTopmostVideo(viewportHeight: self.bounds.height)
            self.videosPlaying = true
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
