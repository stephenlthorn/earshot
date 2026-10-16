import EarshotKit
import SwiftUI

/// The call question in the menu when notifications aren't allowed (spec 7.2): Record or Not now, or Stop or Keep
/// recording. The menu bar icon shows a badge while it waits. The live panel doesn't show it: the panel exists only
/// during a recording, so the menu row and the badge are where the question always waits.
struct CallPromptRow: View {
    let model: AppModel

    var body: some View {
        if let prompt = model.calls.prompt {
            VStack(alignment: .leading, spacing: 6) {
                Label(prompt.text, systemImage: "phone.badge.waveform")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    switch prompt.kind {
                    case .record:
                        Button("Record") { model.answerCallPrompt(prompt, yes: true) }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        Button("Not now") { model.answerCallPrompt(prompt, yes: false) }
                    case .stop:
                        Button("Stop") { model.answerCallPrompt(prompt, yes: true) }
                            .buttonStyle(.borderedProminent)
                        Button("Keep recording") { model.answerCallPrompt(prompt, yes: false) }
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
