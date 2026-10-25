import SwiftUI
import WebKit

private enum ReaderLoadState {
    case loading
    case loaded(chapterID: String, html: String)
    case failed(chapterID: String, message: String)
}

private struct ReaderRequest: Equatable {
    let chapterID: String
    let retry: Int
}

private struct ReaderPagePosition: Equatable {
    let chapterID: String
    let page: Int
    let total: Int
}

struct ReaderView: View {
    let title: String
    let bookID: String
    let chapters: [AudiobookChapter]
    let api: AudiobookAPI
    @ObservedObject var player: PlayerModel
    let onPlayChapter: (AudiobookChapter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedChapterID: String
    @State private var loadState: ReaderLoadState = .loading
    @State private var retryCount = 0
    @State private var showsContents = false
    @State private var pagePosition: ReaderPagePosition?
    @State private var pageTurnRequest = 0
    @State private var followsNarration = true
    @State private var followRequest = 0

    init(title: String, bookID: String, chapters: [AudiobookChapter], initialChapterID: String?,
         api: AudiobookAPI, player: PlayerModel, onPlayChapter: @escaping (AudiobookChapter) -> Void) {
        self.title = title
        self.bookID = bookID
        self.chapters = chapters
        self.api = api
        self.player = player
        self.onPlayChapter = onPlayChapter
        let firstID = chapters.first?.id ?? ""
        _selectedChapterID = State(initialValue: chapters.first(where: { $0.id == initialChapterID })?.id ?? firstID)
    }

    private var selectedIndex: Int? {
        chapters.firstIndex(where: { $0.id == selectedChapterID })
    }

    private var selectedChapter: AudiobookChapter? {
        guard let selectedIndex else { return nil }
        return chapters[selectedIndex]
    }

    private var activeChapterInBook: AudiobookChapter? {
        guard player.activeBookID == bookID,
              let activeID = player.activeChapter?.id else { return nil }
        return chapters.first(where: { $0.id == activeID })
    }

    private var isSelectedChapterPlaying: Bool {
        activeChapterInBook?.id == selectedChapterID && player.isPlaying
    }

    private var activeSegmentID: String? {
        guard activeChapterInBook?.id == selectedChapterID else { return nil }
        return player.currentSegment?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Color.white.ignoresSafeArea())
        .foregroundStyle(Color(red: 0.16, green: 0.16, blue: 0.15))
        .preferredColorScheme(.light)
        .sheet(isPresented: $showsContents) {
            contentsSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: ReaderRequest(chapterID: selectedChapterID, retry: retryCount)) {
            await loadChapter(selectedChapterID)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close reader")

            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 0)

            Button {
                followsNarration = true
                followRequest += 1
            } label: {
                Image(systemName: followsNarration ? "headphones.circle.fill" : "headphones.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(followsNarration ? Color(red: 0.59, green: 0.33, blue: 0.07) : Color.primary)
                    .frame(width: 44, height: 44)
            }
            .disabled(activeSegmentID == nil)
            .accessibilityLabel("Follow narration")
            .accessibilityAddTraits(followsNarration && activeSegmentID != nil ? .isSelected : [])

            Button { showsContents = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Table of contents")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 52)
    }

    @ViewBuilder
    private var content: some View {
        if chapters.isEmpty {
            status(message: "This audiobook has no readable chapters.", retry: false)
        } else {
            switch loadState {
            case .loading:
                ProgressView("Loading chapter")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let chapterID, let html) where chapterID == selectedChapterID:
                ReaderWebView(chapterID: chapterID, html: html, activeSegmentID: activeSegmentID,
                              followsNarration: followsNarration, followRequest: followRequest,
                              pageTurnRequest: pageTurnRequest, onPageChange: { page, total in
                    guard selectedChapterID == chapterID else { return }
                    let next = ReaderPagePosition(chapterID: chapterID, page: page, total: total)
                    if pagePosition != next { pagePosition = next }
                }, onManualPageTurn: {
                    followsNarration = false
                }, onError: { message in
                    guard selectedChapterID == chapterID else { return }
                    loadState = .failed(chapterID: chapterID, message: message)
                })
                    .id(chapterID)
            case .failed(let chapterID, let message) where chapterID == selectedChapterID:
                status(message: message, retry: true)
            default:
                ProgressView("Loading chapter")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func status(message: String, retry: Bool) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "book.closed")
                .font(.system(size: 30, weight: .ultraLight))
            Text(message)
                .font(.system(size: 16))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            if retry {
                Button("Retry") { retryCount += 1 }
                    .font(.system(size: 15, weight: .semibold))
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(Color.black.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            if let selectedIndex {
                Text(footerPosition(chapterIndex: selectedIndex))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.52))
                    .padding(.top, 7)
            }
            HStack {
                pageButton(systemName: "chevron.left", label: "Previous page", direction: -1)
                Spacer()
                Button(action: toggleSelectedChapterPlayback) {
                    Image(systemName: isSelectedChapterPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19))
                        .frame(width: 48, height: 42)
                }
                .accessibilityLabel(isSelectedChapterPlaying ? "Pause audio" : "Play this chapter")
                .disabled(selectedChapter == nil)
                Spacer()
                pageButton(systemName: "chevron.right", label: "Next page", direction: 1)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 26)
            .padding(.bottom, 2)
        }
        .frame(maxWidth: .infinity)
    }

    private func pageButton(systemName: String, label: String, direction: Int) -> some View {
        Button {
            followsNarration = false
            pageTurnRequest += direction
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 48, height: 42)
        }
        .disabled(pagePosition?.chapterID != selectedChapterID ||
                  (direction < 0 ? (pagePosition?.page ?? 1) <= 1 : (pagePosition?.page ?? 1) >= (pagePosition?.total ?? 1)))
        .accessibilityLabel(label)
    }

    private func footerPosition(chapterIndex: Int) -> String {
        if let pagePosition, pagePosition.chapterID == selectedChapterID {
            return "PAGE \(pagePosition.page) OF \(pagePosition.total) IN CHAPTER"
        }
        return "CHAPTER \(chapterIndex + 1) OF \(chapters.count)"
    }

    private var contentsSheet: some View {
        NavigationStack {
            List {
                if let active = activeChapterInBook, active.id != selectedChapterID {
                    Button {
                        selectedChapterID = active.id
                        followsNarration = true
                        showsContents = false
                    } label: {
                        Label("Go to playing chapter", systemImage: "headphones")
                    }
                }
                ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                    Button {
                        selectedChapterID = chapter.id
                        followsNarration = false
                        showsContents = false
                    } label: {
                        HStack(spacing: 14) {
                            Text(String(index + 1))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .leading)
                            Text(displayTitle(chapter))
                                .font(.system(size: 15))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            if chapter.id == selectedChapterID {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .accessibilityHidden(true)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .accessibilityAddTraits(chapter.id == selectedChapterID ? .isSelected : [])
                }
            }
            .listStyle(.plain)
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showsContents = false }
                }
            }
        }
    }

    private func displayTitle(_ chapter: AudiobookChapter) -> String {
        let last = chapter.title.split(separator: "/").last.map(String.init) ?? chapter.title
        let withoutExtension = last.replacingOccurrences(of: #"\.(xhtml|html|htm)$"#, with: "", options: .regularExpression)
        return withoutExtension.isEmpty ? chapter.title : withoutExtension
    }

    private func toggleSelectedChapterPlayback() {
        guard let selectedChapter else { return }
        if activeChapterInBook?.id == selectedChapter.id {
            player.togglePlayback()
        } else {
            followsNarration = true
            onPlayChapter(selectedChapter)
        }
    }

    private func loadChapter(_ chapterID: String) async {
        guard !chapterID.isEmpty else { return }
        loadState = .loading
        pagePosition = nil
        do {
            let html = try await api.readerHTML(bookID: bookID, chapterID: chapterID)
            guard !Task.isCancelled, selectedChapterID == chapterID else { return }
            loadState = .loaded(chapterID: chapterID, html: html)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, selectedChapterID == chapterID else { return }
            loadState = .failed(chapterID: chapterID, message: error.localizedDescription)
        }
    }
}

private struct ReaderWebView: UIViewRepresentable {
    let chapterID: String
    let html: String
    let activeSegmentID: String?
    let followsNarration: Bool
    let followRequest: Int
    let pageTurnRequest: Int
    let onPageChange: (Int, Int) -> Void
    let onManualPageTurn: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(initialPageTurnRequest: pageTurnRequest, initialFollowRequest: followRequest,
                    onPageChange: onPageChange, onManualPageTurn: onManualPageTurn, onError: onError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.scrollView.isPagingEnabled = true
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.delegate = context.coordinator
        context.coordinator.prepare(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(chapterID: chapterID, html: html, in: webView)
        context.coordinator.updateNarration(segmentID: activeSegmentID, followsNarration: followsNarration,
                                            followRequest: followRequest, in: webView)
        context.coordinator.turnPage(ifRequested: pageTurnRequest, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        private let onPageChange: (Int, Int) -> Void
        private let onManualPageTurn: () -> Void
        private let onError: (String) -> Void
        private var rulesReady = false
        private var lastChapterID: String?
        private var pending: (chapterID: String, html: String)?
        private var lastPage: (page: Int, total: Int)?
        private var lastPageTurnRequest: Int
        private var lastFollowRequest: Int
        private var activeSegmentID: String?
        private var displayedSegmentID: String?
        private var followsNarration = true
        private var pageReady = false
        private var highlightRequest = 0
        private var pendingFollowSegmentID: String?
        private var contentSizeObservation: NSKeyValueObservation?

        init(initialPageTurnRequest: Int, initialFollowRequest: Int,
             onPageChange: @escaping (Int, Int) -> Void, onManualPageTurn: @escaping () -> Void,
             onError: @escaping (String) -> Void) {
            lastPageTurnRequest = initialPageTurnRequest
            lastFollowRequest = initialFollowRequest
            self.onPageChange = onPageChange
            self.onManualPageTurn = onManualPageTurn
            self.onError = onError
        }

        func prepare(_ webView: WKWebView) {
            contentSizeObservation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak webView] _, _ in
                DispatchQueue.main.async {
                    guard let self, let webView else { return }
                    self.reportPage(in: webView.scrollView)
                    if self.pageReady, self.followsNarration, self.pendingFollowSegmentID != nil,
                       webView.scrollView.contentSize.width > webView.scrollView.bounds.width {
                        self.applyHighlight(in: webView, shouldFollow: true)
                    }
                }
            }
            // The endpoint embeds its EPUB resources as data URLs. Deny network resources
            // inside WebKit even if a malformed chapter contains an external reference.
            let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "audiobook-reader-no-network", encodedContentRuleList: rules
            ) { [weak self, weak webView] list, _ in
                DispatchQueue.main.async {
                    guard let self, let webView else { return }
                    guard let list else {
                        self.onError("Reader display is unavailable. Please try again.")
                        return
                    }
                    webView.configuration.userContentController.add(list)
                    self.rulesReady = true
                    if let pending = self.pending {
                        self.show(chapterID: pending.chapterID, html: pending.html, in: webView)
                    }
                }
            }
        }

        func show(chapterID: String, html: String, in webView: WKWebView) {
            pending = (chapterID, html)
            guard rulesReady, lastChapterID != chapterID else { return }
            lastChapterID = chapterID
            lastPage = nil
            pageReady = false
            displayedSegmentID = nil
            pendingFollowSegmentID = nil
            highlightRequest += 1
            webView.loadHTMLString(Self.paginated(html), baseURL: nil)
        }

        func updateNarration(segmentID: String?, followsNarration: Bool, followRequest: Int,
                             in webView: WKWebView) {
            let nextID = segmentID.flatMap { Self.isSegmentID($0) ? $0 : nil }
            let segmentChanged = activeSegmentID != nextID
            let followRequested = lastFollowRequest != followRequest
            activeSegmentID = nextID
            self.followsNarration = followsNarration
            if !followsNarration { pendingFollowSegmentID = nil }
            lastFollowRequest = followRequest
            guard pageReady, segmentChanged || followRequested || displayedSegmentID != nextID else { return }
            applyHighlight(in: webView, shouldFollow: followsNarration && (segmentChanged || followRequested))
        }

        private static func isSegmentID(_ id: String) -> Bool {
            guard id.hasPrefix("kaud-"), id.count > 5 else { return false }
            return id.utf8.dropFirst(5).allSatisfy { (48...57).contains($0) }
        }

        private func applyHighlight(in webView: WKWebView, shouldFollow: Bool) {
            let id = activeSegmentID
            displayedSegmentID = id
            pendingFollowSegmentID = shouldFollow ? id : nil
            highlightRequest += 1
            let request = highlightRequest
            // EPUB scripts stay disabled. App code runs in an isolated world and only
            // changes the generated segment marker's presentation.
            let script = """
            const previous = document.querySelector('span[data-reader-active="true"]');
            if (previous) {
                previous.style.removeProperty('background-color');
                previous.style.removeProperty('-webkit-box-decoration-break');
                previous.removeAttribute('data-reader-active');
            }
            const marker = segmentID ? document.getElementById(segmentID) : null;
            if (!marker || marker.tagName !== 'SPAN') return null;
            marker.style.setProperty('background-color', 'rgba(255, 183, 90, 0.34)', 'important');
            marker.style.setProperty('-webkit-box-decoration-break', 'clone', 'important');
            marker.setAttribute('data-reader-active', 'true');
            const rect = marker.getClientRects()[0];
            return rect ? rect.left + window.scrollX : null;
            """
            Task { @MainActor [weak self, weak webView] in
                guard let webView else { return }
                let value = try? await webView.callAsyncJavaScript(
                    script, arguments: ["segmentID": id.map { $0 as Any } ?? NSNull()],
                    in: nil, contentWorld: .world(name: "audiobook-reader")
                )
                guard let self, self.highlightRequest == request,
                      self.followsNarration, shouldFollow else { return }
                guard let x = value as? NSNumber else {
                    self.pendingFollowSegmentID = nil
                    return
                }
                let scrollView = webView.scrollView
                let width = scrollView.bounds.width
                guard width > 0 else { return }
                let absoluteX = max(0, CGFloat(truncating: x))
                if scrollView.contentSize.width <= width { return }
                let maximum = max(0, scrollView.contentSize.width - width)
                let pageX = floor(absoluteX / width) * width
                let targetX = min(pageX, maximum)
                self.pendingFollowSegmentID = nil
                if abs(scrollView.contentOffset.x - targetX) >= width / 2 {
                    scrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: true)
                }
            }
        }

        func turnPage(ifRequested request: Int, in webView: WKWebView) {
            let direction = request - lastPageTurnRequest
            lastPageTurnRequest = request
            guard direction != 0, rulesReady else { return }
            let scrollView = webView.scrollView
            let width = scrollView.bounds.width
            guard width > 0 else { return }
            let maximum = max(0, scrollView.contentSize.width - width)
            let next = min(max(scrollView.contentOffset.x + CGFloat(direction) * width, 0), maximum)
            scrollView.setContentOffset(CGPoint(x: next, y: 0), animated: true)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            followsNarration = false
            pendingFollowSegmentID = nil
            onManualPageTurn()
        }

        private static func paginated(_ html: String) -> String {
            guard let endOfHead = html.range(of: "</head>", options: .caseInsensitive) else { return html }
            let paginationCSS = """
            <style id="reader-pagination">
            html { width: 100% !important; height: 100% !important; overflow-x: auto !important; overflow-y: hidden !important; }
            body { box-sizing: border-box !important; width: 100vw !important; min-width: 100vw !important; max-width: none !important; height: 100vh !important; min-height: 100vh !important; margin: 0 !important; padding: 26px 28px !important; column-width: calc(100vw - 56px) !important; column-gap: 56px !important; column-fill: auto !important; overflow: visible !important; }
            body img, body svg { max-width: 100% !important; max-height: calc(100vh - 52px) !important; object-fit: contain; break-inside: avoid; }
            body table, body pre { max-width: 100%; overflow-wrap: anywhere; }
            body h1, body h2, body h3, body h4, body h5, body h6 { break-after: avoid; }
            body p { orphans: 2; widows: 2; }
            </style>
            """
            var document = html
            document.insert(contentsOf: paginationCSS, at: endOfHead.lowerBound)
            return document
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(url?.scheme == "about" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            applyHighlight(in: webView, shouldFollow: followsNarration)
            reportPage(in: webView.scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            reportPage(in: scrollView)
        }

        private func reportPage(in scrollView: UIScrollView) {
            let width = scrollView.bounds.width
            guard width > 0, scrollView.contentSize.width > 0 else { return }
            let total = max(1, Int(ceil((scrollView.contentSize.width - 1) / width)))
            let page = min(max(Int(round(scrollView.contentOffset.x / width)) + 1, 1), total)
            guard lastPage?.page != page || lastPage?.total != total else { return }
            lastPage = (page, total)
            onPageChange(page, total)
        }
    }
}
