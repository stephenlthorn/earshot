import EarshotKit
import SwiftUI

/// The recording reminder (spec 7.4), with Copy line.
struct ConsentBanner: View {
    let line: String
    let copy: @MainActor () -> Void
    let dismiss: @MainActor () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label("Let everyone know", systemImage: "hand.wave")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.indigoText)
                Spacer()
                HeaderButton(symbol: "xmark", label: "Dismiss the reminder", help: "Dismiss", action: dismiss)
            }
            Text(line)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy line") {
                copy()
                copied = true
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Brand.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// The brief (spec 5.5): headline, points and what was left open last time.
struct BriefCard: View {
    let brief: MeetingBrief
    let expanded: Bool
    let toggle: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack {
                    Label("Brief", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.indigoText)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Brief, collapse" : "Brief, expand")
            if expanded {
                Text(brief.headline).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(brief.points.enumerated()), id: \.offset) { _, point in
                    Bullet(text: point)
                }
                if !brief.openLoops.isEmpty {
                    Text("Open from last time").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.top, 2)
                    ForEach(Array(brief.openLoops.enumerated()), id: \.offset) { _, loop in
                        Bullet(text: "\(loop.owner): \(loop.task) (\(loop.from))")
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct Bullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(Color.secondary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The live to-dos (spec 4.5).
struct LiveTodoList: View {
    static let scrollAfter = 4
    let rows: [LiveRow]
    let actions: LivePanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live to-dos").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if !rows.isEmpty {
                    Text("\(rows.count)").font(.caption2.weight(.semibold)).foregroundStyle(Brand.cyanText)
                }
            }
            if rows.isEmpty {
                Text("To-dos from the call show up here.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else if rows.count > Self.scrollAfter {
                ScrollView { list }.frame(height: 290)
            } else {
                list
            }
        }
    }

    private var list: some View {
        VStack(spacing: 6) {
            ForEach(rows) { row in LiveRowView(row: row, actions: actions) }
        }
    }
}

struct LiveRowView: View {
    let row: LiveRow
    let actions: LivePanelActions
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.task)
                .font(.callout.weight(.medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Chip(text: row.owner, symbol: "person.fill", color: .secondary, fill: Color.primary.opacity(0.06))
                if let due = row.due, !due.isEmpty {
                    Chip(text: due, symbol: "calendar", color: .secondary, fill: Color.primary.opacity(0.06))
                }
                if row.aiDoable { Chip(text: "AI", symbol: "sparkles", color: Brand.cyanText, fill: Brand.cyan.opacity(0.16)) }
                Spacer(minLength: 0)
            }
            if row.state != nil || !row.actions.isEmpty {
                HStack(spacing: 6) {
                    if let state = row.state {
                        Text(state)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color(row.tone))
                            .lineLimit(2)
                            .help(state)
                    }
                    Spacer(minLength: 0)
                    ForEach(Array(row.actions.enumerated()), id: \.offset) { _, action in button(action) }
                }
                .controlSize(.small)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { inside in actions.hover(inside ? row.id : nil) }
    }

    @ViewBuilder
    private func button(_ action: LiveRow.Action) -> some View {
        switch action {
        case .start:
            Button("Start") { actions.start(row.id) }.buttonStyle(.borderedProminent).tint(Brand.indigo)
        case let .setUp(reason):
            Button(LiveRows.setUpButton(for: reason)) { actions.setUp(Self.tab(for: reason)) { openSettings() } }
                .help(reason)
        case .cancel:
            Button("Cancel") { actions.cancel(row.id) }
        case .open:
            Button("Open") { actions.open(row.id) }
        case let .openRun(link):
            Button("Open run") { actions.openRun(link) }
        case .dismiss:
            Button("Dismiss") { actions.dismiss(row.id) }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }

    /// A routine that isn't allowed ("Allow Start in Settings") is a switch in Settings > Live; any other reason
    /// ("Set up a Do target") means the Do tab. Keyed on the reason, not on the button's words, so rewording a label
    /// can't send it to the wrong tab. EarshotKit's LivePanelModelTests pin that reason to the Allow Start button.
    static func tab(for reason: String) -> SettingsTab {
        reason == LiveStartPolicy.routineNotAllowed ? .live : .doTargets
    }

    private func color(_ tone: LiveRow.Tone) -> Color {
        switch tone {
        case .plain: .secondary
        case .working: Brand.cyanText
        case .good: Brand.greenText
        case .bad: Brand.redText
        case .muted: .secondary
        }
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    let color: Color
    let fill: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill, in: Capsule())
    }
}

/// "Listening", "Reading the last two minutes…" and the problems (spec 4.5).
struct StatusLine: View {
    let text: String
    let kind: LivePanelState.StatusKind

    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .listening: Circle().fill(Brand.cyan).frame(width: 7, height: 7)
            case .reading: ProgressView().controlSize(.mini)
            case .problem:
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(Brand.orangeText)
                    .accessibilityLabel("Problem")
            case .off: Circle().fill(Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            }
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// What is being said right now, still tentative: two lines, newest words kept.
struct Ticker: View {
    let me: String
    let them: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line("Them", them)
            line("Me", me)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ who: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(who).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            Text(text.isEmpty ? " " : text).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
        }
    }
}

extension LivePanelState {
    /// Sample values for the README screenshots and previews.
    static let sample = LivePanelState(
        elapsed: 751, flagNote: LivePanelText.flagged(at: 751),
        consentLine: EarshotSettings.defaultConsentLine,
        brief: MeetingBrief(eventID: nil, model: "claude-sonnet-5-5", createdAt: Date(timeIntervalSince1970: 0),
                            headline: "Acme wants the pilot scope before Friday",
                            points: ["Dana's team logs jobs by hand today", "Budget sign-off sits with their CFO"],
                            openLoops: [OpenLoop(owner: "Stephen", task: "Send the case study", from: "Acme intro, 5 Oct")]),
        showsLive: true,
        rows: LiveRows.rows([
            LiveItem(id: "L1", task: "Draft the pilot scope email to Dana", owner: "Stephen", due: "Friday",
                     aiDoable: true, why: "Dana asked for it in writing", firstSeen: 300, status: .running,
                     target: "claude-code"),
            LiveItem(id: "L2", task: "Book a follow-up call with their CFO", owner: "Dana", aiDoable: false,
                     why: "Budget sign-off", firstSeen: 520),
            LiveItem(id: "L3", task: "Compare our pricing tiers with their current tool", owner: "Stephen",
                     aiDoable: true, why: "Dana asked how we compare", firstSeen: 700),
        ], start: .oneClick, pressedAt: [:], now: Date()),
        status: LiveStatus.listening.line, tickerMe: "so the pilot would start on",
        tickerThem: "and we'd want the numbers by Thursday if that works")
}

#Preview("Live panel") {
    LivePanelView(state: .sample).padding()
}
