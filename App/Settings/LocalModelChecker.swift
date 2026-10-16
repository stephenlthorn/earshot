import EarshotKit
import Observation
import SwiftUI

/// The local model status line shared by Settings and onboarding. It runs only `GET <address>/models`, never a model.
@MainActor @Observable
final class LocalModelChecker {
    static let shared = LocalModelChecker()

    private(set) var status: LocalModelStatus?
    private(set) var checking = false
    /// Asked for while a check was running (the address changed meanwhile): the running check goes round again.
    @ObservationIgnored private var checkAgain = false
    /// The running check. It is the checker's own task, not the caller's, so a view that goes away (or a `.task(id:)`
    /// that restarts) never cancels the request and leaves a false "Can't reach" behind.
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Set by `showSample`: the screenshots never contact a server.
    @ObservationIgnored private var sampleOnly = false

    /// Checks the address and model saved in Settings. A call while a check runs makes that check run again when it
    /// ends, so the status always matches the saved address. Returns when the status is saved.
    func check(_ model: AppModel) async {
        guard !sampleOnly else { return }
        if let running {
            checkAgain = true
            await running.value
            return
        }
        checking = true
        let task = Task {
            repeat {
                checkAgain = false
                status = await LocalModelStatus.check(address: model.settings.localURL, model: model.settings.localModel)
            } while checkAgain
            running = nil
            checking = false
        }
        running = task
        await task.value
    }

    var isReady: Bool { status?.state == .ready }

    /// What the server listed at the last check.
    var models: [String] { status?.models ?? [] }

    // Screenshots: a sample status, and no check from then on.
    func showSample(_ status: LocalModelStatus) {
        sampleOnly = true
        self.status = status
    }
}

/// One line with the local model status, an icon, progress while checking and Check. It checks when it appears, and
/// again a moment after the address or the model last changed.
struct LocalModelStatusRow: View {
    @Bindable var model: AppModel
    var checker = LocalModelChecker.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)  // the line says it
            Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if checker.checking { ProgressView().controlSize(.small) }
            Button("Check") { Task { await checker.check(model) } }
                .disabled(checker.checking)
                .controlSize(.small)
        }
        .task(id: [model.settings.localURL, model.settings.localModel]) {
            let delay = LocalModelSetup.checkDelay(last: checker.status, address: model.settings.localURL,
                                                   model: model.settings.localModel)
            if delay > .zero {
                // A newer change cancels this wait, so only the last one is checked.
                guard (try? await Task.sleep(for: delay)) != nil else { return }
            }
            await checker.check(model)
        }
    }

    var line: String {
        if let status = checker.status { return status.summary }
        return checker.checking ? "Checking the local model server…" : "Not checked yet"
    }

    var icon: String {
        guard let status = checker.status else { return "circle.dotted" }
        return status.state == .ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    var tint: Color {
        guard let status = checker.status else { return .secondary }
        return status.state == .ready ? .green : .orange
    }
}
