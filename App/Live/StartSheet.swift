import EarshotKit
import SwiftUI

/// A Start that needs a second click (spec 4.4): the row as drawn, the payload built from it, and the target.
struct StartSheetRequest {
    let item: LiveItem
    let payload: DoPayload
    let target: any DoTarget

    var title: String { LiveStartSheet.title(for: target) }
    var text: String { LiveStartSheet.text(payload, target: target) }
}

/// The sheet's words, as plain values for the panel view.
struct StartSheetModel: Equatable {
    var title: String
    var text: String
}

/// Shown inside the panel in place of the to-do list, since a non-activating panel can't present a real sheet.
struct StartSheetView: View {
    let model: StartSheetModel
    let send: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.title, systemImage: "paperplane")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Brand.indigoText)
            Text("This is exactly what it gets. Nothing is sent until you press Send.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(model.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 200)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.indigo)
            }
            .controlSize(.small)
        }
    }
}
