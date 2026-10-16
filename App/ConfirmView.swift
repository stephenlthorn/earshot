import EarshotKit
import SwiftUI

/// A text field in the confirm window.
enum ConfirmField: Hashable {
    case task(Int), owner(Int), due(Int)
}

/// The confirm window (spec 6): tick, and edit, the items to send. Items started during the call are shown locked.
/// Return in a field moves to the next field and never sends: Send can start work that can't be undone, so while a
/// field is being edited it takes a click.
struct ConfirmView: View {
    let model: AppModel
    /// v2: screenshots. A draft to show instead of a fresh one; nil in the app.
    var sample: ConfirmDraft?
    @State private var draft: ConfirmDraft?
    @FocusState private var focus: ConfirmField?

    var body: some View {
        if let request = model.confirmRequest {
            VStack(alignment: .leading, spacing: 12) {
                Text(request.notes.title).font(.headline)
                Text(request.targets.isEmpty ? "Send these?"
                     : "Send these to \(ListFormatter.localizedString(byJoining: request.targets))?").foregroundStyle(.secondary)
                ForEach(request.problems, id: \.self) { problem in
                    Text(problem).font(.caption).foregroundStyle(Brand.redText)
                }
                if draft != nil {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Binding($draft)!.rows) { $row in
                                ConfirmRow(row: $row, focus: $focus, submit: next)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 420)
                }
                if let problem = draft?.problem { Text(problem).font(.caption).foregroundStyle(Brand.redText) }
                Text("Closing this window skips sending. The notes are kept.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Skip") { model.answerConfirm(nil) }
                    Spacer()
                    Button("Send \(draft?.chosenCount ?? 0)") { send(request) }
                        .keyboardShortcut(focus == nil ? .defaultAction : nil)
                        .disabled(!(draft?.canSend ?? false))
                }
            }
            .padding(20)
            .frame(width: 520)
            .id(request.id)
            .onAppear { draft = sample ?? ConfirmDraft(notes: request.notes, live: request.live, only: request.only) }
        }
    }

    /// Return in a field: task, owner, due, then the next editable row's task, wrapping round to the first.
    func next(after field: ConfirmField) {
        let rows = (draft?.rows ?? []).filter { !$0.startedDuringCall }.map(\.id)
        switch field {
        case .task(let id): focus = .owner(id)
        case .owner(let id): focus = .due(id)
        case .due(let id):
            let following = rows.first { $0 > id } ?? rows.first
            focus = following.map { .task($0) }
        }
    }

    func send(_ request: ConfirmRequest) {
        guard let draft, draft.canSend else { return }
        // The meeting's own style (its profile's), the one its notes were written in (spec 5.3).
        let style = ProfileRules.style(session: request.session, settings: model.settings)
        let lessons = draft.lessons(style: style, title: request.notes.title, date: Date())
        model.answerConfirm(draft.chosenItems, lessons: lessons)
    }
}

/// One item: a tick, the task, owner and due to edit, and whether an AI can do it.
struct ConfirmRow: View {
    @Binding var row: ConfirmDraft.Row
    var focus: FocusState<ConfirmField?>.Binding
    let submit: (ConfirmField) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Labelled with the task, so VoiceOver says which item the tick sends.
            Toggle(row.task.isEmpty ? "Untitled item" : row.task, isOn: $row.chosen).labelsHidden()
                .disabled(row.startedDuringCall)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Task", text: $row.task, axis: .vertical).lineLimit(1...3)
                    .focused(focus, equals: .task(row.id))
                    .onSubmit { submit(.task(row.id)) }
                HStack {
                    TextField("Owner", text: $row.owner).frame(maxWidth: 160)
                        .focused(focus, equals: .owner(row.id))
                        .onSubmit { submit(.owner(row.id)) }
                    TextField("Due", text: $row.due, prompt: Text("No due date")).frame(maxWidth: 140)
                        .focused(focus, equals: .due(row.id))
                        .onSubmit { submit(.due(row.id)) }
                    if row.original.doer == .ai {
                        Label("AI can do this", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if row.startedDuringCall {
                    Label(ConfirmDraft.startedDuringCall, systemImage: "bolt.fill").font(.caption)
                        .foregroundStyle(Brand.orangeText)
                }
            }
            .disabled(row.startedDuringCall)
        }
        .opacity(row.startedDuringCall ? 0.6 : 1)
    }
}
