import Foundation

/// "Send the N new items…" after Do already ran (spec 8). The Ask window keeps which items each target took, so a
/// try after a partial failure, a Fix or an edit in the confirm window sends every item to every target once.
/// "Delivered" maps a target id to the items it took, without `source`.
extension AskRules {
    /// One `Pipeline.sendExtra` call: these items to the targets with these ids.
    public struct ExtraSend: Equatable, Sendable {
        public var items: [ActionItem]
        public var targets: Set<String>

        public init(items: [ActionItem], targets: Set<String>) {
            self.items = items
            self.targets = targets
        }
    }

    /// The sends for the items the person confirmed. Each of `targets` (the ones switched on now) gets only the
    /// items it hasn't taken, and targets missing the same items share one send. In the order of `targets`.
    public static func extraSends(_ items: [ActionItem], targets: [String],
                                  delivered: [String: Set<ActionItem>]) -> [ExtraSend] {
        var sends: [ExtraSend] = []
        for id in targets {
            let missing = Self.missing(items, delivered[id] ?? [])
            guard !missing.isEmpty else { continue }
            if let index = sends.firstIndex(where: { $0.items == missing }) {
                sends[index].targets.insert(id)
            } else {
                sends.append(ExtraSend(items: missing, targets: [id]))
            }
        }
        return sends
    }

    /// `delivered` plus the items of `send` for each of its targets that took them: only those one payload carries
    /// (`DoPayload.carried`), so an item past the cap is still missing and offered again.
    public static func delivered(_ delivered: [String: Set<ActionItem>], after send: ExtraSend,
                                 results: [String: DispatchResult]) -> [String: Set<ActionItem>] {
        let items = Set(DoPayload.carried(send.items).map(NotesDiff.stripped))
        var out = delivered
        for (id, result) in results where result.ok && send.targets.contains(id) {
            out[id, default: []].formUnion(items)
        }
        return out
    }

    /// The ones of `targets` still missing at least one of `items`, in order: the targets a send would reach.
    public static func targetsMissing(_ items: [ActionItem], targets: [String],
                                      delivered: [String: Set<ActionItem>]) -> [String] {
        targets.filter { !missing(items, delivered[$0] ?? []).isEmpty }
    }

    static func missing(_ items: [ActionItem], _ had: Set<ActionItem>) -> [ActionItem] {
        items.filter { !had.contains(NotesDiff.stripped($0)) }
    }
}
