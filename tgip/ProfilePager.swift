import SwiftUI
import AppKit

// AppKit-backed horizontal pager for the profile pages.
//
// Why this exists: a SwiftUI ScrollView + LazyHStack re-runs layout/body and
// creates/destroys pages during the swipe — ~15ms per frame for rich pages, so it
// never feels buttery. Here each page is hosted once in its own layer-backed
// NSHostingView; the pager is a real NSScrollView, so the swipe just translates the
// cached page layers on the GPU (native momentum + elastic), and SwiftUI only
// re-renders a page when its data changes — never per frame.
//
// Nested scrolling: each page's own (vertical) scroll view handles vertical swipes
// and forwards the perpendicular (horizontal) axis to this enclosing NSScrollView —
// AppKit's built-in behaviour — so horizontal swipes page between profiles while
// vertical swipes scroll within a page.
struct ProfilePager: NSViewRepresentable {
    let pageCount: Int
    let activeIndex: Int
    /// Builds page `i`'s content. Inject any needed environment here.
    let makePage: (Int) -> AnyView
    /// Called when the user swipes to a different page.
    let onSwitch: (Int) -> Void

    func makeNSView(context: Context) -> PagerScrollView {
        let view = PagerScrollView()
        view.onSwitch = onSwitch
        view.update(pageCount: pageCount, activeIndex: activeIndex, makePage: makePage)
        return view
    }

    func updateNSView(_ view: PagerScrollView, context: Context) {
        view.onSwitch = onSwitch
        view.update(pageCount: pageCount, activeIndex: activeIndex, makePage: makePage)
    }
}

final class PagerScrollView: NSScrollView {
    var onSwitch: ((Int) -> Void)?

    private let content = NSView()                       // documentView; holds pages
    private var pages: [NSHostingView<AnyView>] = []
    private var displayedIndex = 0
    private var lastReported = 0
    private var snapWorkItem: DispatchWorkItem?
    private var scrollMonitor: Any?
    private var burstDX: CGFloat = 0   // accumulated horizontal scroll for the current burst

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .allowed   // rubber-band at the ends
        verticalScrollElasticity = .none        // outer pager never scrolls vertically
        drawsBackground = false
        contentView.drawsBackground = false
        content.wantsLayer = true
        documentView = content
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    // SwiftUI's inner vertical ScrollView swallows the horizontal axis instead of
    // forwarding it to this enclosing scroll view, so nested routing alone never
    // pages. A local scroll monitor sees every scroll event regardless of which
    // view is under the cursor: horizontal-dominant scrolls over this pager drive
    // paging (and are consumed); everything else passes through untouched so the
    // page's own vertical scrolling still works.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event) ?? event
            }
        } else if window == nil, let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    private func handleScroll(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, pages.count > 1 else { return event }
        let pointInSelf = convert(event.locationInWindow, from: nil)
        guard bounds.contains(pointInSelf) else { return event }
        // Vertical-dominant → let the page scroll itself.
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }

        burstDX += event.scrollingDeltaX
        // Live follow, but clamped to the immediate neighbours so a burst commits at
        // most one page (Arc-style one-swipe-one-profile).
        let width = pageWidth
        let lo = CGFloat(clamp(displayedIndex - 1)) * width
        let hi = CGFloat(clamp(displayedIndex + 1)) * width
        let x = min(max(contentView.bounds.origin.x - event.scrollingDeltaX, lo), hi)
        contentView.setBoundsOrigin(NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
        scheduleSnap()
        return nil  // consume — don't let the inner view also act on it
    }

    private var pageWidth: CGFloat { contentView.bounds.width }

    func update(pageCount: Int, activeIndex: Int, makePage: (Int) -> AnyView) {
        if pages.count != pageCount {
            pages.forEach { $0.removeFromSuperview() }
            pages = (0..<pageCount).map { index in
                let host = NSHostingView(rootView: makePage(index))
                host.translatesAutoresizingMaskIntoConstraints = true
                content.addSubview(host)
                return host
            }
            displayedIndex = clamp(activeIndex)
            lastReported = displayedIndex
            layoutPages()
            scroll(toPage: displayedIndex, animated: false)
            return
        }

        // Same page set — refresh content (cheap; SwiftUI diffs). Runs on data
        // changes, NOT during the swipe.
        for (index, host) in pages.enumerated() {
            host.rootView = makePage(index)
        }

        // Programmatic switch (ProfileBar / keyboard): animate to the new page.
        let target = clamp(activeIndex)
        if target != displayedIndex {
            displayedIndex = target
            lastReported = target
            scroll(toPage: target, animated: window != nil)
        }
    }

    override func layout() {
        super.layout()
        layoutPages()
        scroll(toPage: displayedIndex, animated: false)
    }

    private func clamp(_ index: Int) -> Int { max(0, min(index, max(pages.count - 1, 0))) }

    private func layoutPages() {
        let width = contentView.bounds.width
        let height = contentView.bounds.height
        content.frame = NSRect(x: 0, y: 0, width: width * CGFloat(max(pages.count, 1)), height: height)
        for (index, page) in pages.enumerated() {
            page.frame = NSRect(x: width * CGFloat(index), y: 0, width: width, height: height)
        }
    }

    private func scroll(toPage index: Int, animated: Bool, completion: (() -> Void)? = nil) {
        let width = pageWidth
        guard width > 0 else { completion?(); return }
        let origin = NSPoint(x: width * CGFloat(index), y: 0)
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                contentView.animator().setBoundsOrigin(origin)
            }, completionHandler: completion)
            reflectScrolledClipView(contentView)
        } else {
            contentView.setBoundsOrigin(origin)
            reflectScrolledClipView(contentView)
            completion?()
        }
    }

    private func scheduleSnap() {
        snapWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.snapToNearestPage() }
        snapWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func snapToNearestPage() {
        let width = pageWidth
        guard width > 0, !pages.isEmpty else { return }
        // Commit on a small, deliberate scroll rather than requiring a half-page drag.
        let threshold: CGFloat = 15
        var target = displayedIndex
        if burstDX <= -threshold { target = clamp(displayedIndex + 1) }
        else if burstDX >= threshold { target = clamp(displayedIndex - 1) }
        burstDX = 0
        displayedIndex = target
        lastReported = target
        // Slide first (pure Core Animation over already-rendered pages); run the
        // heavy profile switch only AFTER the slide settles, so the expensive state
        // change + re-render storm don't stutter the animation.
        scroll(toPage: target, animated: true) { [weak self] in
            guard let self, self.displayedIndex == target else { return }
            self.onSwitch?(target)
        }
    }
}
