import Foundation

/// Everything `notes.html` shows for one meeting (spec 10).
public struct NotesPageInput: Equatable, Sendable {
    public var notes: MeetingNotes
    public var session: Session
    /// The merged transcript (transcript.json), on the meeting clock.
    public var transcript: [Segment]
    /// Speaker names by track; a missing name falls back to the track's default name.
    public var names: [Track: String]
    public var brief: MeetingBrief?
    public var liveItems: [LiveItem]
    public var screenMoments: [ScreenMoment]
    /// One status per notes action item, from `ItemStatus.compute`.
    public var statuses: [String]
    /// Each action item's routine run, from `ItemStatus.cloudRuns`; missing means none.
    public var cloudRuns: [String?]
    public var timeZone: TimeZone

    public init(notes: MeetingNotes, session: Session, transcript: [Segment] = [], names: [Track: String] = [:],
                brief: MeetingBrief? = nil, liveItems: [LiveItem] = [], screenMoments: [ScreenMoment] = [],
                statuses: [String] = [], cloudRuns: [String?] = [], timeZone: TimeZone = .current) {
        self.notes = notes
        self.session = session
        self.transcript = transcript
        self.names = names
        self.brief = brief
        self.liveItems = liveItems
        self.screenMoments = screenMoments
        self.statuses = statuses
        self.cloudRuns = cloudRuns
        self.timeZone = timeZone
    }
}

/// Renders `notes.html`: one self-contained page with inline CSS, no scripts and no remote resources. Every text is
/// HTML-escaped. The only links are https run links, relative links to files in the meeting folder and `#t-<seconds>`
/// anchors into the transcript.
public enum NotesPageRenderer {
    /// Longest text shown for one timeline entry; the full line is in the transcript.
    static let timelineClip = 160

    public static func html(_ input: NotesPageInput) -> String {
        let lines = anchoredLines(input)
        let body = [header(input), summary(input.notes), brief(input.brief),
                    listSection("Still open from before", input.notes.stillOpen, style: "open"),
                    listSection("Decisions", input.notes.decisions, style: "decisions"),
                    actionItems(input), flaggedMoments(input.notes, lines: lines),
                    listSection("Key points", input.notes.keyPoints, style: "points"),
                    listSection("Open questions", input.notes.openQuestions, style: "questions"),
                    timeline(input, lines: lines), transcript(lines), footer(input)]
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(escape(input.notes.title))</title>
        <style>\(Style.css)</style>
        </head>
        <body>
        <div class="bar"></div>
        <main class="page">
        \(body.filter { !$0.isEmpty }.joined(separator: "\n"))
        </main>
        </body>
        </html>

        """
    }

    // MARK: Safety

    /// Escapes `&`, `<`, `>`, `"` and `'`, so text is safe in element content and in quoted attributes. It works
    /// per Unicode scalar: a grapheme cluster such as "\u{0600}<" holds a real "<" that the browser still parses.
    public static func escape(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            case "'": out.append(contentsOf: "&#39;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// `text` when it is an https URL with a host and nothing that could break out of an attribute; otherwise nil.
    public static func httpsLink(_ text: String) -> String? {
        let unsafe = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'<>\\`"))
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ !unsafe.contains($0) && $0.isASCII }),
              let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, text.lowercased().hasPrefix("https://")
        else { return nil }
        return text
    }

    /// A percent-encoded relative path to a file inside the meeting folder, or nil for anything else: absolute
    /// paths, `..`, schemes, queries, fragments, backslashes and `~`.
    public static func relativeLink(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              path.rangeOfCharacter(from: CharacterSet(charactersIn: ":?#\\\"'<>`")) == nil,
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":;")
        return path.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// The link to a kept screenshot. `ScreenMoment.image` is a file name under `screen/`; a name with a "/" in it
    /// (or anything `relativeLink` refuses) gets no link.
    static func screenshotLink(_ name: String) -> String? {
        guard !name.contains("/") else { return nil }
        return relativeLink(MeetingFile.screenFolder + "/" + name)
    }

    // MARK: Sections

    static func header(_ input: NotesPageInput) -> String {
        let session = input.session
        var chips = ["<li>\(escape(NotesRenderer.dateText(session.startedAt, input.timeZone)))</li>",
                     "<li>\(escape(NotesRenderer.lengthText(session.duration)))</li>",
                     "<li class=\"tag\">\(escape(session.mode.label))</li>"]
        switch session.profile {
        case .external?: chips.append("<li class=\"tag alt\">External</li>")
        case .internal?: chips.append("<li class=\"tag alt\">Internal</li>")
        case .noEvent?, nil: break
        }
        var attendees = input.notes.attendees.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if attendees.isEmpty { attendees = session.calendarEvent?.others.map(\.displayName) ?? [] }
        let with = attendees.isEmpty ? "" : "\n<p class=\"with\">With \(escape(attendees.joined(separator: ", ")))</p>"
        return """
        <header>
        <div class="brand"><span class="mark"></span>Earshot meeting notes</div>
        <h1>\(escape(input.notes.title))</h1>
        <ul class="meta">\(chips.joined())</ul>\(with)
        </header>
        """
    }

    static func summary(_ notes: MeetingNotes) -> String {
        let text = notes.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return section("Summary", style: "summary", "<p>\(escape(text))</p>")
    }

    static func brief(_ brief: MeetingBrief?) -> String {
        guard let brief else { return "" }
        let headline = brief.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let points = brief.points.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !headline.isEmpty || !points.isEmpty else { return "" }
        let lead = headline.isEmpty ? "" : "<p class=\"lead\">\(escape(headline))</p>"
        return section("Before the call", style: "brief", lead + bullets(points))
    }

    static func listSection(_ title: String, _ items: [String], style: String) -> String {
        let items = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !items.isEmpty else { return "" }
        return section(title, style: style, bullets(items))
    }

    static func actionItems(_ input: NotesPageInput) -> String {
        let items = input.notes.actionItems
        guard !items.isEmpty else { return "" }
        let started = input.liveItems.filter(\.status.isStarted)
        let rows = items.enumerated().map { index, item in
            let status = index < input.statuses.count ? input.statuses[index] : ""
            let ai = item.doer == .ai ? "<span class=\"badge ai\">AI</span>" : ""
            let context = item.context.trimmingCharacters(in: .whitespacesAndNewlines)
            let contextHTML = context.isEmpty ? "" : "<span class=\"ctx\">\(escape(context))</span>"
            let due = item.due.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            var statusHTML = status.isEmpty ? "" : "<span class=\"status \(statusClass(status))\">\(escape(status))</span>"
            if let run = ItemStatus.linkedLiveItem(item, live: started)?.link.flatMap(httpsLink) {
                statusHTML += "<a class=\"run\" href=\"\(escape(run))\">Open the run</a>"
            } else if status == ItemStatus.startedInCloud,
                      let run = (index < input.cloudRuns.count ? input.cloudRuns[index] : nil).flatMap(httpsLink) {
                statusHTML += "<a class=\"run\" href=\"\(escape(run))\">Open run</a>"
            }
            return "<tr><td class=\"owner\">\(escape(item.owner))</td>"
                + "<td><span class=\"task\">\(escape(item.task))</span>\(ai)\(contextHTML)</td>"
                + "<td class=\"due\">\(due.map(escape) ?? "<span class=\"none\">None</span>")</td>"
                + "<td>\(statusHTML)</td></tr>"
        }
        let table = "<div class=\"card\"><table><thead><tr><th>Owner</th><th>Task</th><th>Due</th><th>Status</th></tr>"
            + "</thead><tbody>\(rows.joined(separator: "\n"))</tbody></table></div>"
        return section("Action items", style: "items", table)
    }

    static func statusClass(_ status: String) -> String {
        if status == ItemStatus.startedDuringCall || status == ItemStatus.startedInCloud { return "started" }
        return status.hasPrefix("Sent to ") ? "sent" : "plain"
    }

    static func flaggedMoments(_ notes: MeetingNotes, lines: [AnchoredLine]) -> String {
        let moments = notes.flaggedMoments.sorted { $0.seconds < $1.seconds }
        guard !moments.isEmpty else { return "" }
        let items = moments.map { moment in
            "<li>\(timeLink(moment.seconds, lines: lines))<span>\(escape(moment.note))</span></li>"
        }
        return section("Flagged moments", style: "flags", "<ul class=\"moments\">\(items.joined())</ul>")
    }

    static func timeline(_ input: NotesPageInput, lines: [AnchoredLine]) -> String {
        let events = timelineEvents(input, lines: lines).sorted { ($0.seconds, $0.order) < ($1.seconds, $1.order) }
        guard !events.isEmpty else { return "" }
        var out: [String] = []
        var minute = -1
        for event in events {
            let thisMinute = NotesRenderer.wholeSeconds(event.seconds) / 60
            if thisMinute != minute {
                if minute >= 0 { out.append("</ol></li>") }
                minute = thisMinute
                out.append("<li class=\"minute\"><span class=\"mark-time\">\(NotesRenderer.clock(Double(thisMinute * 60)))</span><ol>")
            }
            out.append(event.html)
        }
        out.append("</ol></li>")
        return section("Timeline", style: "timeline", "<ol class=\"track\">\(out.joined())</ol>")
    }

    static func timelineEvents(_ input: NotesPageInput, lines: [AnchoredLine]) -> [TimelineEvent] {
        let turns = lines.map { line in
            TimelineEvent(seconds: line.line.start, order: 0, html: "<li class=\"event\">"
                + "<a class=\"at\" href=\"#\(line.anchor)\">\(NotesRenderer.clock(line.line.start))</a>"
                + "<span class=\"who \(line.track.rawValue)\">\(escape(line.line.speaker))</span>"
                + "<span class=\"said\">\(escape(clip(line.line.text, timelineClip)))</span></li>")
        }
        let flags = input.session.flags.map { flag in
            let note = nearestNote(flag.offset, in: input.notes.flaggedMoments).map { " \(escape($0))" } ?? ""
            return TimelineEvent(seconds: flag.offset, order: 1, html: "<li class=\"event\">"
                + "<span class=\"at\">\(NotesRenderer.clock(flag.offset))</span>"
                + "<span class=\"kind flag\">Flagged</span><span class=\"said\">\(note)</span></li>")
        }
        let screens = input.screenMoments.map { moment in
            let shot = moment.image.flatMap(screenshotLink).map { " <a href=\"\(escape($0))\">Screenshot</a>" } ?? ""
            return TimelineEvent(seconds: moment.offset, order: 2, html: "<li class=\"event\">"
                + "<span class=\"at\">\(NotesRenderer.clock(moment.offset))</span>"
                + "<span class=\"kind screen\">On screen</span>"
                + "<span class=\"said\">\(escape(clip(moment.text, timelineClip)))\(shot)</span></li>")
        }
        return turns + flags + screens
    }

    static func transcript(_ lines: [AnchoredLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let rows = lines.map { line in
            "<p class=\"line\" id=\"\(line.anchor)\"><a class=\"at\" href=\"#\(line.anchor)\">"
                + "\(NotesRenderer.clock(line.line.start))</a><span><span class=\"who \(line.track.rawValue)\">"
                + "\(escape(line.line.speaker))</span> \(escape(line.line.text))</span></p>"
        }
        let count = lines.count == 1 ? "1 line" : "\(lines.count) lines"
        return section("Full transcript", style: "transcript",
                       "<details open><summary>The transcript (\(count))</summary><div class=\"lines\">"
                           + rows.joined(separator: "\n") + "</div></details>")
    }

    static func footer(_ input: NotesPageInput) -> String {
        var links = ["<a href=\"\(MeetingFile.notesMarkdown)\">Markdown notes</a>"]
        if !input.transcript.isEmpty { links.append("<a href=\"\(MeetingFile.transcriptMarkdown)\">Transcript file</a>") }
        let runs = input.session.routineRuns.sorted { $0.key < $1.key }.compactMap { id, url in
            httpsLink(url).map { "<a href=\"\(escape($0))\">Routine run \(escape(id))</a>" }
        }
        return "<footer><span>Written by Earshot</span>\((links + runs).joined())</footer>"
    }

    // MARK: Pieces

    struct AnchoredLine {
        var line: TranscriptLine
        var track: Track
        var anchor: String
    }

    struct TimelineEvent {
        var seconds: Double
        var order: Int
        var html: String
    }

    /// Transcript lines with their `t-<seconds>` anchors; a second line in the same second gets `t-<seconds>-2`.
    static func anchoredLines(_ input: NotesPageInput) -> [AnchoredLine] {
        var used: [Int: Int] = [:]
        return input.transcript.map { segment in
            let second = NotesRenderer.wholeSeconds(segment.start)
            let count = (used[second] ?? 0) + 1
            used[second] = count
            let speaker = TranscriptLine.speaker(segment.track, names: input.names)
            return AnchoredLine(line: TranscriptLine(start: segment.start, speaker: speaker, text: segment.text),
                                track: segment.track, anchor: count == 1 ? "t-\(second)" : "t-\(second)-\(count)")
        }
    }

    /// The time as mm:ss, linked to the last transcript line at or before it (or the first line).
    static func timeLink(_ seconds: Double, lines: [AnchoredLine]) -> String {
        let clock = NotesRenderer.clock(seconds)
        let whole = NotesRenderer.wholeSeconds(seconds)
        guard let target = lines.last(where: { NotesRenderer.wholeSeconds($0.line.start) <= whole }) ?? lines.first
        else { return "<span class=\"time\">\(clock)</span>" }
        return "<a class=\"time\" href=\"#\(target.anchor)\">\(clock)</a>"
    }

    /// The flagged-moment note the model wrote for a flag at `seconds`, when one is within 15 seconds.
    static func nearestNote(_ seconds: Double, in moments: [FlaggedMoment]) -> String? {
        moments.filter { abs($0.seconds - seconds) <= 15 }
            .min { abs($0.seconds - seconds) < abs($1.seconds - seconds) }?.note
    }

    static func section(_ title: String, style: String, _ content: String) -> String {
        "<section class=\"\(style)\"><h2>\(escape(title))</h2>\(content)</section>"
    }

    static func bullets(_ items: [String]) -> String {
        "<ul class=\"list\">" + items.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "..."
    }
}

extension NotesPageRenderer {
    /// The page's only styles: brand palette, system fonts, light and dark, small screens and print.
    enum Style {
        static let css = #"""
        :root{--ink:#0F0E1A;--paper:#F7F7FB;--card:#FFFFFF;--muted:#5D5B73;--faint:#8A88A0;--line:#E6E5EF;
        --indigo:#4F46E5;--violet:#8B5CF6;--cyan:#22D3EE;--accent:#4F46E5;--accent-soft:#EEEDFD;
        --violet-ink:#7C3AED;--violet-soft:#F3EEFE;--cyan-ink:#0E7490;--cyan-soft:#E3F8FC;
        --me:#4F46E5;--them:#7C3AED;--shadow:0 1px 2px rgba(15,14,26,.04),0 8px 24px rgba(15,14,26,.05)}
        @media (prefers-color-scheme: dark){:root{--ink:#ECEBF7;--paper:#0F0E1A;--card:#17162A;--muted:#A9A7C2;
        --faint:#77758F;--line:#2A2843;--accent:#A5A0FF;--accent-soft:#25234D;--violet-ink:#C4B0FF;
        --violet-soft:#2B2050;--cyan-ink:#7DE9F8;--cyan-soft:#0F2F38;--me:#A5A0FF;--them:#C4B0FF;--shadow:none}}
        *{box-sizing:border-box}
        html{-webkit-text-size-adjust:100%}
        body{margin:0;background:var(--paper);color:var(--ink);font:16px/1.6 -apple-system,BlinkMacSystemFont,
        "SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased;
        overflow-wrap:anywhere}
        .bar{height:4px;background:linear-gradient(90deg,var(--indigo),var(--violet) 55%,var(--cyan))}
        .page{max-width:880px;margin:0 auto;padding:56px 24px 72px}
        a{color:var(--accent);text-decoration:none}
        a:hover{text-decoration:underline}
        .brand{display:flex;align-items:center;gap:8px;font-size:12px;font-weight:600;letter-spacing:.09em;
        text-transform:uppercase;color:var(--muted)}
        .mark{width:14px;height:14px;border-radius:50%;background:conic-gradient(from 210deg,var(--indigo),
        var(--violet),var(--cyan),var(--indigo))}
        h1{font-size:36px;line-height:1.15;letter-spacing:-.022em;font-weight:700;margin:14px 0 16px;
        text-wrap:balance}
        .meta{display:flex;flex-wrap:wrap;gap:8px;list-style:none;margin:0;padding:0}
        .meta li{font-size:13px;line-height:1;padding:7px 11px;border-radius:999px;background:var(--card);
        border:1px solid var(--line);color:var(--muted)}
        .meta li.tag{background:var(--accent-soft);border-color:transparent;color:var(--accent);font-weight:600}
        .meta li.alt{background:var(--violet-soft);color:var(--violet-ink)}
        .with{margin:16px 0 0;color:var(--muted);font-size:15px}
        section{margin-top:44px}
        h2{display:flex;align-items:center;gap:12px;margin:0 0 14px;font-size:12px;font-weight:700;
        letter-spacing:.09em;text-transform:uppercase;color:var(--muted)}
        h2::after{content:"";flex:1;height:1px;background:var(--line)}
        .summary p{margin:0;font-size:19px;line-height:1.65;letter-spacing:-.005em;text-wrap:pretty}
        .lead{margin:0 0 6px;font-weight:600}
        .list{list-style:none;margin:0;padding:0}
        .list li{position:relative;padding:7px 0 7px 24px}
        .list li::before{content:"";position:absolute;left:3px;top:16px;width:8px;height:8px;border-radius:50%;
        background:var(--violet)}
        .decisions .list li::before{border-radius:2px;background:var(--accent);transform:rotate(45deg)}
        .open .list li::before{background:transparent;border:2px solid var(--cyan)}
        .questions .list li::before{background:var(--faint)}
        .card,details{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow);
        overflow:hidden}
        table{width:100%;border-collapse:collapse;font-size:15px}
        th{text-align:left;padding:12px 16px;border-bottom:1px solid var(--line);font-size:11px;font-weight:700;
        letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
        td{padding:14px 16px;border-bottom:1px solid var(--line);vertical-align:top}
        tbody tr:last-child td{border-bottom:0}
        td.owner{font-weight:600;white-space:nowrap}
        td.due{color:var(--muted);white-space:nowrap}
        .task{font-weight:600}
        .ctx{display:block;margin-top:3px;font-size:13px;line-height:1.5;color:var(--muted)}
        .none{color:var(--faint)}
        .badge{display:inline-block;margin-left:8px;padding:2px 7px;border-radius:6px;font-size:10px;font-weight:800;
        letter-spacing:.08em;vertical-align:2px}
        .badge.ai{color:#FFFFFF;background:linear-gradient(135deg,var(--indigo),var(--violet))}
        .status{display:inline-block;padding:4px 10px;border-radius:999px;font-size:12px;font-weight:600;
        line-height:1.3;border:1px solid var(--line);color:var(--muted)}
        .status.started{background:var(--cyan-soft);border-color:transparent;color:var(--cyan-ink)}
        .status.sent{background:var(--accent-soft);border-color:transparent;color:var(--accent)}
        .run{display:block;margin-top:6px;font-size:12px;font-weight:600}
        .moments{list-style:none;margin:0;padding:0}
        .moments li{display:flex;gap:14px;align-items:baseline;padding:8px 0}
        .time{flex:none;display:inline-block;min-width:58px;padding:4px 8px;border-radius:7px;text-align:center;
        font:600 12px/1.2 ui-monospace,"SF Mono",Menlo,monospace;color:var(--violet-ink);background:var(--violet-soft)}
        .track{list-style:none;margin:0 0 0 6px;padding:0 0 0 24px;border-left:2px solid var(--line)}
        .track ol{list-style:none;margin:0;padding:0}
        .minute{position:relative;padding-top:6px}
        .minute+.minute{margin-top:14px}
        .minute::before{content:"";position:absolute;left:-32px;top:9px;width:10px;height:10px;border-radius:50%;
        background:var(--paper);border:2px solid var(--violet)}
        .mark-time{display:block;margin-bottom:4px;font:700 12px/1.4 ui-monospace,"SF Mono",Menlo,monospace;
        color:var(--muted)}
        .event{display:flex;gap:10px;align-items:baseline;padding:3px 0;font-size:14px;line-height:1.5}
        .at{flex:none;width:42px;font:12px ui-monospace,"SF Mono",Menlo,monospace;color:var(--faint)}
        .who{flex:none;font-weight:600}
        .who.me{color:var(--me)}
        .who.them,.who.speaker{color:var(--them)}
        .said{color:var(--ink)}
        .kind{flex:none;padding:2px 7px;border-radius:6px;font-size:10px;font-weight:800;letter-spacing:.08em;
        text-transform:uppercase}
        .kind.flag{color:var(--violet-ink);background:var(--violet-soft)}
        .kind.screen{color:var(--cyan-ink);background:var(--cyan-soft)}
        summary{cursor:pointer;padding:15px 20px;font-weight:600;list-style:none}
        summary::-webkit-details-marker{display:none}
        summary::before{content:"\25B8";display:inline-block;width:18px;color:var(--violet)}
        details[open] summary::before{content:"\25BE"}
        .lines{padding:0 20px 12px}
        .line{display:grid;grid-template-columns:52px 1fr;gap:12px;margin:0;padding:8px 0;font-size:15px;
        border-top:1px solid var(--line);scroll-margin-top:24px}
        .line .at{width:auto;padding-top:3px}
        .line:target{background:var(--accent-soft);box-shadow:-20px 0 0 var(--accent-soft),20px 0 0 var(--accent-soft)}
        footer{display:flex;flex-wrap:wrap;gap:6px 20px;margin-top:56px;padding-top:20px;border-top:1px solid var(--line);
        font-size:13px;color:var(--muted)}
        footer span{margin-right:auto}
        @media (max-width:640px){.page{padding:36px 16px 56px}h1{font-size:28px}.summary p{font-size:17px}
        thead{display:none}table,tbody,tr,td{display:block}tr{padding:12px 16px;border-bottom:1px solid var(--line)}
        tbody tr:last-child{border-bottom:0}td{padding:2px 0;border:0}td.due::before{content:"Due: "}.event{flex-wrap:wrap}}
        @media print{:root{--ink:#000000;--paper:#FFFFFF;--card:#FFFFFF;--muted:#444444;--faint:#666666;--line:#CCCCCC;
        --shadow:none;--accent:#3730A3;--me:#3730A3;--them:#5B21B6}
        body{font-size:11pt;-webkit-print-color-adjust:exact;print-color-adjust:exact}
        .page{max-width:none;padding:0}.bar{display:none}section{margin-top:24pt}
        a{color:inherit}h2{break-after:avoid}tr,li,.line{break-inside:avoid}
        details::details-content{content-visibility:visible;display:block}
        summary::before{content:""}.line:target{background:none;box-shadow:none}}
        """#
    }
}
