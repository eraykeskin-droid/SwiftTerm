//
//  OffMainTerminalFeed.swift
//
//  EKODE fork (branch ekode/offmain): lets a host parse a TerminalView's output on a
//  background queue while the view keeps drawing, selecting and encoding input on main.
//
#if os(macOS)
import Foundation

/// Takes a `TerminalView`'s place as its `Terminal`'s delegate so the terminal can be fed
/// from a background thread.
///
/// Threading contract: the host serialises every access to `terminal` between the thread
/// that feeds it and the main thread (one lock both take; the view itself takes none). Only
/// then may `feed` run off main.
///
/// Delegate calls the parser makes:
/// - replies to what `feed` parsed (`send`: device attributes, cursor reports, colour queries)
///   go to `replyHandler` on the feeding thread, in order, and only while the view has a
///   `terminalDelegate` (the view drops them otherwise, too);
/// - on the main thread outside `feed` (a resize, a mouse report, the synchronized-output
///   timeout) every call goes to the view unchanged, as without this object;
/// - off main, the synchronous questions (`windowCommand`, `cellSizeInPixels`, `getColors`,
///   `isProcessTrusted`, image creation) are answered by the view on the calling thread, which
///   the host's lock makes safe; `clipboardRead` is denied;
/// - every other call is recorded and delivered to the view by `publishOnMain()`, coalesced:
///   one `scrolled` per batch instead of one per line.
public final class OffMainTerminalFeed: TerminalDelegate {
    public let terminal: Terminal
    public private(set) weak var view: TerminalView?
    /// Called on the feeding thread with every reply the parser produces (device attributes,
    /// cursor position reports, colour queries), in order.
    public var replyHandler: ((ArraySlice<UInt8>) -> Void)?
    /// True during `feed` (on the feeding thread).
    private var feeding = false

    private let lock = NSLock()
    private var pending = Pending()

    private struct Pending {
        var scrolled = false
        var linefeed = false
        var bufferActivated = false
        var sizeChanged = false
        var synchronizedOutputEnded = false
        var mouseModeChanged = false
        var selectionChanged = false
        var cursorVisible: Bool?
        var cursorStyle: CursorStyle?
        var title: String?
        var iconTitle: String?
        var hostDirectoryChanged = false
        var hostDocumentChanged = false
        var allColorsChanged = false
        var changedColors: [Int] = []
        var foreground: Color?
        var background: Color?
        var cursorColor: Color??
        var progress: Terminal.ProgressReport?
        /// Calls that are delivered one by one, in order (bell, OSC 52 writes, notifications).
        var events: [(TerminalView, Terminal) -> Void] = []

        var isEmpty: Bool {
            !scrolled && !linefeed && !bufferActivated && !sizeChanged && !synchronizedOutputEnded
                && !mouseModeChanged && !selectionChanged && cursorVisible == nil && cursorStyle == nil
                && title == nil && iconTitle == nil && !hostDirectoryChanged && !hostDocumentChanged
                && !allColorsChanged && changedColors.isEmpty && foreground == nil && background == nil
                && cursorColor == nil && progress == nil && events.isEmpty
        }
    }

    /// On main. Installs this object as `view.terminal`'s delegate; `detach()` gives it back.
    public init(view: TerminalView) {
        self.view = view
        self.terminal = view.terminal
        terminal.tdel = self
    }

    /// On main: the view becomes the terminal's delegate again (after `publishOnMain()`).
    public func detach() {
        publishOnMain()
        if let view, terminal.tdel === self { terminal.tdel = view }
    }

    /// On the feeding thread (or main), holding the host's lock.
    public func feed(_ bytes: ArraySlice<UInt8>) {
        feeding = true
        defer { feeding = false }
        terminal.feed(buffer: bytes)
    }

    /// On main, holding the host's lock, after one or more `feed` calls: delivers what the
    /// parser reported and asks the view to redraw, as `TerminalView.feed` does after parsing.
    public func publishOnMain() {
        let batch: Pending = lock.withLock {
            let batch = pending
            pending = Pending()
            return batch
        }
        guard let view else { return }
        deliver(batch, to: view)
        view.outputDidChangeOffMain(sawLinefeed: batch.linefeed)
    }

    /// Whether `publishOnMain()` has anything to deliver besides the redraw.
    public var hasPendingCalls: Bool { lock.withLock { !pending.isEmpty } }

    private func deliver(_ batch: Pending, to view: TerminalView) {
        let terminal = self.terminal
        let delegate: TerminalDelegate = view
        if batch.bufferActivated { delegate.bufferActivated(source: terminal) }
        if batch.sizeChanged { delegate.sizeChanged(source: terminal) }
        if batch.scrolled { delegate.scrolled(source: terminal, yDisp: terminal.buffer.yDisp) }
        if batch.mouseModeChanged { delegate.mouseModeChanged(source: terminal) }
        if let style = batch.cursorStyle { delegate.cursorStyleChanged(source: terminal, newStyle: style) }
        if let visible = batch.cursorVisible {
            visible ? delegate.showCursor(source: terminal) : delegate.hideCursor(source: terminal)
        }
        if batch.allColorsChanged {
            delegate.colorChanged(source: terminal, idx: nil)
        } else {
            for index in batch.changedColors { delegate.colorChanged(source: terminal, idx: index) }
        }
        if let color = batch.foreground { delegate.setForegroundColor(source: terminal, color: color) }
        if let color = batch.background { delegate.setBackgroundColor(source: terminal, color: color) }
        if let color = batch.cursorColor { delegate.setCursorColor(source: terminal, color: color) }
        if batch.synchronizedOutputEnded { delegate.synchronizedOutputChanged(source: terminal, active: false) }
        if let title = batch.title { delegate.setTerminalTitle(source: terminal, title: title) }
        if let title = batch.iconTitle { delegate.setTerminalIconTitle(source: terminal, title: title) }
        if batch.hostDirectoryChanged { delegate.hostCurrentDirectoryUpdated(source: terminal) }
        if batch.hostDocumentChanged { delegate.hostCurrentDocumentUpdated(source: terminal) }
        if batch.selectionChanged { delegate.selectionChanged(source: terminal) }
        if let report = batch.progress { delegate.progressReport(source: terminal, report: report) }
        for event in batch.events { event(view, terminal) }
    }

    /// Main thread: `body` runs now on the view. Otherwise it is recorded for `publishOnMain()`.
    private func onMain(_ forward: (TerminalDelegate) -> Void, else record: (inout Pending) -> Void) {
        if Thread.isMainThread {
            if let view { forward(view) }
        } else {
            lock.withLock { record(&pending) }
        }
    }

    // MARK: TerminalDelegate

    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        if !feeding, Thread.isMainThread {
            view?.send(source: source, data: data)
        } else if view?.terminalDelegate != nil {
            replyHandler?(data)
        }
    }

    public func showCursor(source: Terminal) {
        onMain({ $0.showCursor(source: source) }, else: { $0.cursorVisible = true })
    }

    public func hideCursor(source: Terminal) {
        onMain({ $0.hideCursor(source: source) }, else: { $0.cursorVisible = false })
    }

    public func setTerminalTitle(source: Terminal, title: String) {
        onMain({ $0.setTerminalTitle(source: source, title: title) }, else: { $0.title = title })
    }

    public func setTerminalIconTitle(source: Terminal, title: String) {
        onMain({ $0.setTerminalIconTitle(source: source, title: title) }, else: { $0.iconTitle = title })
    }

    public func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? {
        guard let view else { return nil }
        return (view as TerminalDelegate).windowCommand(source: source, command: command)
    }

    public func sizeChanged(source: Terminal) {
        onMain({ $0.sizeChanged(source: source) }, else: { $0.sizeChanged = true })
    }

    public func scrolled(source: Terminal, yDisp: Int) {
        onMain({ $0.scrolled(source: source, yDisp: yDisp) }, else: { $0.scrolled = true })
    }

    public func linefeed(source: Terminal) {
        onMain({ $0.linefeed(source: source) }, else: { $0.linefeed = true })
    }

    public func bufferActivated(source: Terminal) {
        onMain({ $0.bufferActivated(source: source) }, else: { $0.bufferActivated = true })
    }

    public func synchronizedOutputChanged(source: Terminal, active: Bool) {
        // The view acts only on the end of a synchronized frame.
        onMain({ $0.synchronizedOutputChanged(source: source, active: active) },
               else: { $0.synchronizedOutputEnded = !active || $0.synchronizedOutputEnded })
    }

    public func bell(source: Terminal) {
        onMain({ $0.bell(source: source) }, else: { $0.events.append { $0.bell(source: $1) } })
    }

    public func selectionChanged(source: Terminal) {
        onMain({ $0.selectionChanged(source: source) }, else: { $0.selectionChanged = true })
    }

    public func isProcessTrusted(source: Terminal) -> Bool {
        guard let view else { return false }
        return (view as TerminalDelegate).isProcessTrusted(source: source)
    }

    public func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? {
        guard let view else { return nil }
        return (view as TerminalDelegate).cellSizeInPixels(source: source)
    }

    public func mouseModeChanged(source: Terminal) {
        onMain({ $0.mouseModeChanged(source: source) }, else: { $0.mouseModeChanged = true })
    }

    public func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        onMain({ $0.cursorStyleChanged(source: source, newStyle: newStyle) }, else: { $0.cursorStyle = newStyle })
    }

    public func hostCurrentDirectoryUpdated(source: Terminal) {
        onMain({ $0.hostCurrentDirectoryUpdated(source: source) }, else: { $0.hostDirectoryChanged = true })
    }

    public func hostCurrentDocumentUpdated(source: Terminal) {
        onMain({ $0.hostCurrentDocumentUpdated(source: source) }, else: { $0.hostDocumentChanged = true })
    }

    public func colorChanged(source: Terminal, idx: Int?) {
        onMain({ $0.colorChanged(source: source, idx: idx) }, else: { pending in
            if let idx { pending.changedColors.append(idx) } else { pending.allColorsChanged = true }
        })
    }

    public func setForegroundColor(source: Terminal, color: Color) {
        onMain({ $0.setForegroundColor(source: source, color: color) }, else: { $0.foreground = color })
    }

    public func setBackgroundColor(source: Terminal, color: Color) {
        onMain({ $0.setBackgroundColor(source: source, color: color) }, else: { $0.background = color })
    }

    public func setCursorColor(source: Terminal, color: Color?) {
        onMain({ $0.setCursorColor(source: source, color: color) }, else: { $0.cursorColor = .some(color) })
    }

    public func getColors(source: Terminal) -> (foreground: Color, background: Color) {
        guard let view else { return (source.foregroundColor, source.backgroundColor) }
        return (view as TerminalDelegate).getColors(source: source)
    }

    public func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {
        let copy = Array(content)
        onMain({ $0.iTermContent(source: source, content: content) },
               else: { $0.events.append { $0.iTermContent(source: $1, content: copy[...]) } })
    }

    public func clipboardCopy(source: Terminal, content: Data) {
        onMain({ $0.clipboardCopy(source: source, content: content) },
               else: { $0.events.append { $0.clipboardCopy(source: $1, content: content) } })
    }

    /// Off main the clipboard is never read: the answer would have to come synchronously from
    /// the host's delegate, which lives on main.
    public func clipboardRead(source: Terminal) -> Data? {
        guard Thread.isMainThread, let view else { return nil }
        return (view as TerminalDelegate).clipboardRead(source: source)
    }

    public func notify(source: Terminal, title: String, body: String) {
        onMain({ $0.notify(source: source, title: title, body: body) },
               else: { $0.events.append { $0.notify(source: $1, title: title, body: body) } })
    }

    public func progressReport(source: Terminal, report: Terminal.ProgressReport) {
        onMain({ $0.progressReport(source: source, report: report) }, else: { $0.progress = report })
    }

    public func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        guard let view else { return }
        (view as TerminalDelegate).createImageFromBitmap(source: source, bytes: &bytes, width: width, height: height)
    }

    public func createImage(source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest,
                            preserveAspectRatio: Bool) {
        guard let view else { return }
        (view as TerminalDelegate).createImage(source: source, data: data, width: width, height: height,
                                               preserveAspectRatio: preserveAspectRatio)
    }
}

extension TerminalView {
    /// On main, after the terminal was fed elsewhere (`OffMainTerminalFeed`): what `feed` does
    /// around parsing. Search results are stale; with `allowMouseReporting` the selection is
    /// cleared as streamed output would clear it; the view redraws on its usual cadence.
    func outputDidChangeOffMain(sawLinefeed: Bool) {
        search.invalidate()
        if allowMouseReporting {
            selection.active = false
            if sawLinefeed { selection.selectNone() }
        }
        feedFinish()
    }
}
#endif
