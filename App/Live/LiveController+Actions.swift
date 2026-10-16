import AppKit
import EarshotKit

/// What the panel's buttons and the hotkeys do.
extension LiveController {
    // MARK: Flags and layout

    /// A flag at the meeting clock now. A hotkey flag plays "Tink" once it is saved; the panel shows
    /// "Flagged at mm:ss" for every saved flag.
    func flag(_ source: FlagSource) {
        guard let live, began else { return }
        Task {
            if await live.flag(source) != nil, source == .hotkey { NSSound(named: "Tink")?.play() }
        }
    }

    /// The Sharing button and ⌃⌥⌘H: a content-free pill, and back.
    func toggleSharing() {
        guard live != nil, model?.livePanelVisible == true else { return }
        layout = layout == .sharing ? .full : .sharing
    }

    func toggleCollapsed() {
        layout = layout == .full ? .collapsed : .full
    }

    func toggleBrief() {
        briefCard.toggle()
    }

    func stopRecording() {
        model?.stopRecording()
    }

    // MARK: Consent

    func copyConsentLine() {
        guard let line = consent?.line else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    func dismissConsent() {
        consent = nil
    }

    // MARK: Live to-dos

    /// Start, per `LiveStartPolicy`: one click (with the "Starting… Cancel" window), or the sheet that shows exactly
    /// what will be sent. The payload is built from the row as drawn now.
    /// Only AI-doable rows offer Start (spec 4). The target follows `LiveTargetChoice`: the chosen one, or the first
    /// working one while the chosen one is off.
    func start(_ id: String) {
        guard let live, let model, let row = items.first(where: { $0.id == id }), LiveRows.offersStart(row) else {
            return
        }
        let settings = model.settings
        let choice = LiveTargetChoice.make(settings: settings, targets: settings.targets(secrets: model.keychain))
        let decision = choice.decision
        startDecision = self.decision(settings)
        guard startDecision != nil, let target = choice.target else { return }
        let clickedAt = Date()
        Task {
            let payload = await live.payload(for: row, at: clickedAt)
            // The live assistant may have been switched off while the payload was read: then nothing is sent.
            guard self.live === live, liveOn, startDecision != nil else { return }
            switch decision {
            case .oneClick:
                pressedAt[id] = clickedAt
                if !(await live.start(row, payload: payload, target: target, confirmed: false)) { pressedAt[id] = nil }
            case .confirmSheet:
                sheet = StartSheetRequest(item: row, payload: payload, target: target)
                freezeHovered()
            case .unavailable:
                break
            }
        }
    }

    /// The second click in the sheet: sends exactly what the sheet showed, with no cancel window.
    func confirmSheet() {
        guard let request = sheet, let live else { return }
        sheet = nil
        guard liveOn else {  // switched off while the sheet was open: nothing new is sent
            freezeHovered()
            return
        }
        Task {
            _ = await live.start(request.item, payload: request.payload, target: request.target, confirmed: true)
            freezeHovered()
        }
    }

    func cancelSheet() {
        sheet = nil
        freezeHovered()
    }

    func cancel(_ id: String) {
        guard let live else { return }
        pressedAt[id] = nil
        Task { await live.cancel(id) }
    }

    func dismiss(_ id: String) {
        guard let live else { return }
        Task {
            do {
                try await live.dismiss(id)
            } catch {
                Self.log.error("Dismiss of a live to-do failed: \(error.localizedDescription, privacy: .public)")
                if self.live === live { saveProblem = LivePanelText.couldNotSave }
            }
        }
    }

    /// "Set up a Do target" or "Allow Start in Settings": chooses the tab (Do, or Live for the Start switch), brings
    /// Earshot forward first, so Settings doesn't open behind a full-screen call, then opens it.
    func openSettings(_ tab: SettingsTab, _ open: @MainActor () -> Void) {
        model?.settingsTab = tab
        NSApp.activate()
        open()
    }

    /// Done: the Claude Code work folder (where drafts are saved), else the target's log in the meeting folder.
    func open(_ id: String) {
        guard let live, let model, let item = items.first(where: { $0.id == id }) else { return }
        let folder = live.store.folder
        if item.target == LiveStartPolicy.TargetKind.claudeCode.rawValue {
            let work = (model.settings.claudeCodeFolder.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .expandingTildeInPath
            if !work.isEmpty, EarshotSettings.isFolder(work) {
                NSWorkspace.shared.open(URL(fileURLWithPath: work, isDirectory: true))
                return
            }
        }
        if let target = item.target {
            let log = folder.appending(path: MeetingFile.doLog(target))
            if FileManager.default.fileExists(atPath: log.path) {
                NSWorkspace.shared.open(log)
                return
            }
        }
        NSWorkspace.shared.open(folder)
    }

    func openRun(_ link: String) {
        guard let url = URL(string: link), url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    /// Rows freeze while the pointer is over them, so a pass never changes the row about to be clicked.
    func setHovered(_ id: String?) {
        hovered = id
        freezeHovered()
    }

    private func freezeHovered() {
        guard let live else { return }
        let frozen = Set([hovered, sheet?.item.id].compactMap { $0 })
        Task { await live.setFrozen(frozen) }
    }

    // MARK: The panel's values

    func panelState() -> LivePanelState {
        let problem = transcriptionProblem ?? saveProblem
        let kind: LivePanelState.StatusKind = switch status {
        case _ where problem != nil: .problem
        case .reading?: .reading
        case .failed?, .paused?: .problem
        case .listening?, nil: .listening
        }
        return LivePanelState(
            elapsed: elapsed, layout: layout, flagNote: flagNote, consentLine: consent?.line, brief: brief,
            briefExpanded: briefCard.expanded, showsLive: liveOn || liveSwitchedOff, liveStopped: liveSwitchedOff,
            rows: LiveRows.rows(items, start: startDecision, pressedAt: pressedAt, now: now),
            // Once switched off, a Dismiss that couldn't be saved still shows ahead of the off line.
            status: liveSwitchedOff ? saveProblem ?? RecordingSwitches.liveOffLine
                : liveOn ? problem ?? status?.line(provider: liveProvider)
                    ?? LiveStatus.listening.line : nil,
            statusKind: liveSwitchedOff ? (saveProblem == nil ? .off : .problem) : kind,
            tickerMe: tickerMe, tickerThem: tickerThem,
            sheet: sheet.map { StartSheetModel(title: $0.title, text: $0.text) },
            hidesFromCapture: model?.settings.hidePanelFromCapture ?? true)
    }

    func panelActions() -> LivePanelActions {
        LivePanelActions(
            flag: { [weak self] in self?.flag(.panel) },
            sharing: { [weak self] in self?.toggleSharing() },
            stop: { [weak self] in self?.stopRecording() },
            collapse: { [weak self] in self?.toggleCollapsed() },
            copyConsent: { [weak self] in self?.copyConsentLine() },
            dismissConsent: { [weak self] in self?.dismissConsent() },
            toggleBrief: { [weak self] in self?.toggleBrief() },
            start: { [weak self] in self?.start($0) },
            cancel: { [weak self] in self?.cancel($0) },
            dismiss: { [weak self] in self?.dismiss($0) },
            setUp: { [weak self] in self?.openSettings($0, $1) },
            open: { [weak self] in self?.open($0) },
            openRun: { [weak self] in self?.openRun($0) },
            hover: { [weak self] in self?.setHovered($0) },
            confirmSheet: { [weak self] in self?.confirmSheet() },
            cancelSheet: { [weak self] in self?.cancelSheet() })
    }
}
