import Foundation

/// Sends started live to-dos, one run at a time per target, in the order Start was pressed (spec 3.2 and 4.4).
///
/// For each item: `queued` is saved at once; after the cancel window (none when the user already confirmed in the
/// sheet), and once the target is free, `sending` is saved through `LiveStore` before the target is called (and
/// `running` too for Claude Code, which works on the Mac). Only the result changes it after that. If `sending` can't
/// be saved, nothing is sent.
///
/// One queue serves one meeting. "One run at a time per target" holds across meetings too: a job starts only once
/// it holds its target's lane in `TargetLanes`, which every queue and the pipeline's sends share, so a finished
/// meeting's run, the next meeting's Start and a post-call send never run the same target at once.
public actor LiveRunQueue {
    /// A status change, for the panel.
    public struct Update: Equatable, Sendable {
        public var id: String
        public var status: LiveItem.Status
        public var target: String?
        public var detail: String?
        public var link: String?

        public init(id: String, status: LiveItem.Status, target: String? = nil, detail: String? = nil,
                    link: String? = nil) {
            self.id = id
            self.status = status
            self.target = target
            self.detail = detail
            self.link = link
        }
    }

    public static let notSaved = "Earshot couldn't save the live to-dos, so nothing was sent."

    private struct Job {
        let id: String
        /// This press of Start. A later press of the same item is another job, so an old window can't start it.
        let token = UUID()
        let payload: DoPayload
        let target: any DoTarget
        var ready: Bool
        /// The cancel window's task, in `tasks`.
        var window: UUID?
    }

    private let store: LiveStore
    private let cancelWindow: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onStatus: @Sendable (Update) -> Void

    /// Waiting jobs, first in first out, per target id.
    private var lanes: [String: [Job]] = [:]
    /// Target ids with a run going.
    private var running: Set<String> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Set by `hold()`: no job is started from then on.
    private let held = Locked(false)
    private let targetLanes: TargetLanes
    /// Per target id, the task (in `tasks`) waiting for a lane another queue or the pipeline holds.
    private var laneWaits: [String: UUID] = [:]

    public init(store: LiveStore, cancelWindow: Duration = LiveStartPolicy.cancelWindow,
                lanes: TargetLanes = .shared,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                onStatus: @escaping @Sendable (Update) -> Void = { _ in }) {
        self.store = store
        self.targetLanes = lanes
        self.cancelWindow = cancelWindow
        self.sleep = sleep
        self.onStatus = onStatus
    }

    /// Queues `snapshot` (the row exactly as drawn) for `target`, and records its words with `queued`, so live.json
    /// holds what is sent. Returns false, and changes nothing, when the queue is held (the recording stopped, so a
    /// Start whose press lands after Stop is left to the notes), the item is waiting in this queue or started, or
    /// `queued` can't be saved. A stored `queued` this queue doesn't hold is stale (a save failed after it) and
    /// doesn't block.
    /// - Parameter confirmed: true when the user already confirmed in the sheet, so there is no cancel window.
    @discardableResult
    public func enqueue(snapshot: LiveItem, payload: DoPayload, send target: any DoTarget,
                        confirmed: Bool = false) -> Bool {
        let id = snapshot.id
        let current = store.items.first { $0.id == id }?.status ?? snapshot.status
        guard !held.get, !current.isStarted, !isQueued(id) else { return false }
        guard (try? store.queue(snapshot, target: target.id)) != nil else { return false }
        report(Update(id: id, status: .queued, target: target.id))
        var job = Job(id: id, payload: payload, target: target, ready: confirmed)
        if !confirmed {
            let token = job.token
            job.window = track { [cancelWindow, sleep] in
                try? await sleep(cancelWindow)
                await self.windowPassed(token, target: target.id)
            }
        }
        lanes[target.id, default: []].append(job)
        pump(target.id)
        return true
    }

    /// Takes the item back before it is sent, during the cancel window or while it waits for its target. Returns
    /// false once sending has begun. A ready job behind it on the same target is started.
    @discardableResult
    public func cancel(_ id: String) -> Bool {
        for (target, jobs) in lanes {
            guard let index = jobs.firstIndex(where: { $0.id == id }) else { continue }
            let job = jobs[index]
            lanes[target]?.remove(at: index)
            if let window = job.window { tasks[window]?.cancel() }
            // Nothing left for that target: stop waiting for its lane, so `waitUntilIdle()` isn't held up.
            if lanes[target]?.isEmpty ?? true, let wait = laneWaits.removeValue(forKey: target) { tasks[wait]?.cancel() }
            try? store.setStatus(id, .suggested)
            report(Update(id: id, status: .suggested))
            pump(target)
            return true
        }
        return false
    }

    /// From now on no job is started; jobs still waiting stay queued until they are cancelled. Synchronous, so the
    /// App can call it before it stops the programs it started at quit, and a run that ends then can't start the
    /// next one.
    public nonisolated func hold() {
        held.update { $0 = true }
    }

    /// Returns when nothing is waiting or running, for example at stop.
    public func waitUntilIdle() async {
        while let task = tasks.values.first {
            await task.value
        }
    }

    private func isQueued(_ id: String) -> Bool {
        lanes.values.contains { $0.contains { $0.id == id } }
    }

    /// The window of one press of Start ended. A job cancelled in it is gone, and a later press has its own token.
    private func windowPassed(_ token: UUID, target: String) {
        if let index = lanes[target]?.firstIndex(where: { $0.token == token }) {
            lanes[target]?[index].ready = true
        }
        pump(target)
    }

    /// Starts the first job for `target` when it is ready and the target is free, here and in every other queue and
    /// send (`TargetLanes`). A target busy elsewhere is waited for, and the job stays queued (and cancellable).
    private func pump(_ target: String) {
        guard !held.get, !running.contains(target), let job = lanes[target]?.first, job.ready else { return }
        guard targetLanes.tryAcquire(target) else {
            waitForLane(target)
            return
        }
        lanes[target]?.removeFirst()
        let kind = LiveStartPolicy.TargetKind(id: target)
        do {
            try store.setStatus(job.id, .sending, target: target)
            report(Update(id: job.id, status: .sending, target: target))
            if kind == .claudeCode {
                try store.setStatus(job.id, .running, target: target)
                report(Update(id: job.id, status: .running, target: target))
            }
        } catch {
            targetLanes.release(target)
            fail(job.id, target: target)
            pump(target)
            return
        }
        running.insert(target)
        let folder = store.folder
        track {
            let result: DispatchResult
            do {
                result = await job.target.send(job.payload, json: try job.payload.encoded(), folder: folder)
            } catch {
                result = DispatchResult(ok: false, detail: error.localizedDescription)
            }
            await self.finished(job.id, target: target, kind: kind, result: result)
        }
    }

    private func finished(_ id: String, target: String, kind: LiveStartPolicy.TargetKind?, result: DispatchResult) {
        let status: LiveItem.Status = if result.interrupted {
            .interrupted
        } else if !result.ok {
            .failed
        } else {
            switch kind {
            case .claudeCode?, .command?: .done
            case .routine?: .startedInCloud
            case .webhook?, nil: .sent
            }
        }
        let update = Update(id: id, status: status, target: target, detail: result.detail.isEmpty ? nil : result.detail,
                            link: result.link)
        // The panel still learns the result if live.json can't be written; recover() then marks it interrupted.
        try? store.setStatus(id, status, target: target, detail: update.detail, link: update.link)
        report(update)
        running.remove(target)
        targetLanes.release(target)
        pump(target)
    }

    /// Waits, once per target, for the lane someone else holds, then tries again.
    private func waitForLane(_ target: String) {
        guard laneWaits[target] == nil else { return }
        let lanes = targetLanes
        let key = UUID()
        laneWaits[target] = key
        track(key: key) {
            await lanes.released(target)
            await self.laneFreed(target, key: key)
        }
    }

    private func laneFreed(_ target: String, key: UUID) {
        guard laneWaits[target] == key else { return }
        laneWaits[target] = nil
        pump(target)
    }

    private func fail(_ id: String, target: String) {
        try? store.setStatus(id, .failed, target: target, detail: Self.notSaved)
        report(Update(id: id, status: .failed, target: target, detail: Self.notSaved))
    }

    private func report(_ update: Update) {
        onStatus(update)
    }

    /// Runs `work` as a task that `waitUntilIdle()` waits for, and returns its key in `tasks`.
    @discardableResult
    private func track(key: UUID = UUID(), _ work: @escaping @Sendable () async -> Void) -> UUID {
        tasks[key] = Task {
            await work()
            self.untrack(key)
        }
        return key
    }

    /// How many tasks are going (windows and sends), for tests.
    var trackedCount: Int { tasks.count }

    private func untrack(_ key: UUID) {
        tasks[key] = nil
    }
}
