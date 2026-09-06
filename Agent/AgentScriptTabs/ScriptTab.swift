import Foundation
import AppKit

/// A chunk of long text pasted into the task input. Rendered as a removable
/// chip above the TextField; prepended to the prompt at task-run time.
struct PastedText: Identifiable, Equatable {
    let id: UUID
    let text: String
    init(_ text: String) {
        self.id = UUID()
        self.text = text
    }
}

/// Thread-safe boolean flag for cross-thread cancellation checks.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}

@MainActor @Observable
final class ScriptTab: Identifiable {
    let id: UUID
    let scriptName: String
    var activityLog: String = ""
    var isRunning: Bool = true {
        didSet {
            // Clear stale LLM output when a script-only tab starts a new run
            if isRunning && !isLLMRunning && !isLLMThinking && !isMainTab {
                rawLLMOutput = ""
                llmMessages = []
                tabInputTokens = 0
                tabOutputTokens = 0
                thinkingDismissed = true
            }
        }
    }
    var isCancelled: Bool = false {
        didSet { if isCancelled { _cancelFlag.set() } }
    }
    var exitCode: Int32?
    var cancelHandler: (() -> Void)?

    /// Thread-safe flag readable from any thread (for Sendable closures)
    nonisolated let _cancelFlag = AtomicFlag()

    // MARK: - Multi-Main-Tab LLM Config

    /// Non-nil when this is a "Main" tab with its own LLM provider/model
    var llmConfig: LLMConfig?
    /// Which main tab spawned this script tab (for LLM inheritance)
    var parentTabId: UUID?
    /// Whether this tab acts as an independent main tab
    var isMainTab: Bool { llmConfig != nil }
    /// Whether this is the dedicated Messages tab (for iMessage Agent! commands)
    var isMessagesTab: Bool = false
    /// The iMessage handle to reply to when a Messages tab task completes
    var replyHandle: String?
    /// Display name: scriptName (numbered for duplicate LLM tabs; "Messages" for iMessage tab)
    var displayTitle: String { isMessagesTab ? "Messages" : scriptName }

    // Log buffering (mirrors AgentViewModel pattern)
    var logBuffer = ""
    var logFlushTask: Task<Void, Never>?
    var streamLineCount = 0

    // MARK: - LLM Conversation State

    var taskInput: String = ""
    var isLLMRunning: Bool = false
    var isLLMThinking: Bool = false
    var thinkingDismissed: Bool = true
    var thinkingExpanded: Bool = false
    var thinkingOutputExpanded: Bool = false
    /// Expanded state for tool steps disclosure (persists across toggles and launches, keyed by tab id)
    var toolStepsExpanded: Bool = false {
        didSet { UserDefaults.standard.set(toolStepsExpanded, forKey: "tab.\(id.uuidString).toolStepsExpanded") }
    }
    /// User's drag-resized height for the LLM Output HUD on this tab. Persisted across tab switches and launches (keyed by tab id).
    var llmOutputHeight: Double = 80 {
        didSet { UserDefaults.standard.set(llmOutputHeight, forKey: "tab.\(id.uuidString).llmOutputHeight") }
    }

    /// Unified busy check — true when the tab is doing anything (running, LLM, thinking)
    var isBusy: Bool { isRunning || isLLMRunning || isLLMThinking }
    var runningLLMTask: Task<Void, Never>?
    var llmMessages: [[String: Any]] = []
    var taskQueue: [String] = []
    var currentTaskPrompt: String = ""
    var currentAppleAIPrompt: String = ""
    /// Tool names recorded by the running tab task (mirrors the tab loop's local
    /// `commandsRun`). Read by the completion gates so the verify build sees the
    /// tab's edits, not the main loop's.
    var taskCommandsRun: [String] = []

    // MARK: - Per-Tab Project Folder

    /// Each tab can have its own project folder
    var projectFolder: String = ""

    // MARK: - Per-Tab Prompt History

    var promptHistory: [String] = []
    var historyIndex: Int = -1
    var savedInput: String = ""

    // MARK: - Per-Tab Task & Error History

    var tabTaskSummaries: [String] = []
    var tabErrors: [String] = []

    // MARK: - Tool Steps (structured tool call tracking)

    var toolSteps: [AgentViewModel.ToolStep] = []

    @discardableResult
    func recordToolStep(name: String, detail: String) -> UUID {
        let step = AgentViewModel.ToolStep(name: name, detail: detail, startTime: Date())
        toolSteps.append(step)
        return step.id
    }

    func completeToolStep(id: UUID, status: AgentViewModel.ToolStep.Status = .success) {
        if let idx = toolSteps.firstIndex(where: { $0.id == id }) {
            toolSteps[idx].duration = Date().timeIntervalSince(toolSteps[idx].startTime)
            toolSteps[idx].status = status
        }
    }

    // MARK: - Per-Tab Attached Images

    var attachedImages: [NSImage] = []
    var attachedImagesBase64: [String] = []
    /// Snapshot of attachments at task start — survives after the input
    /// buffers are cleared so copy_image(source:"chat") can still find them.
    var taskScopeImages: [NSImage] = []

    // MARK: - Per-Tab Pasted Text Attachments

    /// Long text pastes are captured as attachments (chips) instead of being
    /// inserted inline into the TextField — SwiftUI's TextField beach-balls
    /// on very long content. Prepended to the prompt when the task runs.
    var pastedTexts: [PastedText] = []

    // LLM streaming state
    var llmStreamBuffer: String = ""
    var rawLLMOutput: String = ""
    /// Character-by-character dripped version of rawLLMOutput for terminal effect
    var displayedLLMOutput: String = ""
    var dripDisplayIndex: Int = 0
    var dripTask: Task<Void, Never>?
    var lastElapsed: Double = 0
    var taskStartDate: Date? // Set when task starts, nil when idle
    var taskElapsed: Double { // Computes live elapsed — works even when tab is in background
        get {
            if let start = taskStartDate, isRunning || isLLMRunning {
                return Date().timeIntervalSince(start)
            }
            return _taskElapsedFrozen
        }
        set { _taskElapsedFrozen = newValue }
    }
    var _taskElapsedFrozen: Double = 0 // Stored value when task stops
    var tabInputTokens: Int = 0
    var tabOutputTokens: Int = 0
    var llmStreamFlushTask: Task<Void, Never>?
    var llmStreamingStarted: Bool = false

    init(scriptName: String, id: UUID = UUID()) {
        self.id = id
        self.scriptName = scriptName
    }

    /// Create a new main tab with its own LLM configuration
    init(llmConfig: LLMConfig, id: UUID = UUID()) {
        self.id = id
        self.scriptName = llmConfig.displayName
        self.llmConfig = llmConfig
        self.isRunning = false
    }

    /// Restore a tab from persisted SwiftData record
    init(record: ScriptTabRecord) {
        self.id = record.tabId
        self.scriptName = record.scriptName
        // Truncation handled by ActivityLogView at render time
        self.activityLog = record.activityLog
        self.exitCode = record.exitCode == -999 ? nil : Int32(record.exitCode)
        self.isRunning = false
        self.isMessagesTab = record.isMessagesTab
        self.projectFolder = record.projectFolder
        // Restore LLM config if present
        if let json = record.llmConfigJSON, let data = json.data(using: .utf8) {
            self.llmConfig = try? JSONDecoder().decode(LLMConfig.self, from: data)
        }
        if let parentStr = record.parentTabIdString {
            self.parentTabId = UUID(uuidString: parentStr)
        }
        if let json = record.promptHistoryJSON, let data = json.data(using: .utf8),
           let history = try? JSONDecoder().decode([String].self, from: data)
        {
            self.promptHistory = history
        }
        if let json = record.taskSummariesJSON, let data = json.data(using: .utf8),
           let summaries = try? JSONDecoder().decode([String].self, from: data)
        {
            self.tabTaskSummaries = summaries
        }
        if let json = record.errorsJSON, let data = json.data(using: .utf8),
           let errors = try? JSONDecoder().decode([String].self, from: data)
        {
            self.tabErrors = errors
        }
        self.rawLLMOutput = record.rawLLMOutput
        self.displayedLLMOutput = record.rawLLMOutput // Show full text on restore (no drip)
        self.dripDisplayIndex = record.rawLLMOutput.unicodeScalars.count
        self.lastElapsed = record.lastElapsed
        self.thinkingExpanded = record.thinkingExpanded
        self.thinkingOutputExpanded = record.thinkingOutputExpanded
        // If there's LLM output, show the indicator (don't dismiss)
        self.thinkingDismissed = record.rawLLMOutput.isEmpty ? true : record.thinkingDismissed
        self.tabInputTokens = record.tabInputTokens
        self.tabOutputTokens = record.tabOutputTokens
        // Restore the last task's Steps list so the HUD shows it after relaunch
        if let json = record.toolStepsJSON, let data = json.data(using: .utf8),
           let steps = try? JSONDecoder().decode([AgentViewModel.ToolStep].self, from: data)
        {
            self.toolSteps = steps
        }
        // Per-tab HUD layout state (UserDefaults keyed by tab id — not in the SwiftData record)
        let defaults = UserDefaults.standard
        if let h = defaults.object(forKey: "tab.\(id.uuidString).llmOutputHeight") as? Double {
            self.llmOutputHeight = h
        }
        if let e = defaults.object(forKey: "tab.\(id.uuidString).toolStepsExpanded") as? Bool {
            self.toolStepsExpanded = e
        }
    }

    // MARK: - Logging

    func appendOutput(_ text: String) {
        guard !text.isEmpty else { return }
        let newlines = text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        streamLineCount += max(newlines, 1)
        logBuffer += text
        if !text.hasSuffix("\n") { logBuffer += "\n" }
        scheduleFlush()
    }

    func appendLog(_ message: String) {
        let timestamp = AgentViewModel.timestampFormatter.string(from: Date())
        AgentViewModel.prepareLogBuffer(message: message, buffer: &logBuffer, existingLog: activityLog)
        // Multi-line messages (diffs, edit payloads) drop onto their own line
        // so the first content line isn't jammed next to the timestamp.
        if message.contains("\n") {
            logBuffer += "[\(timestamp)]\n\(message)\n"
        } else {
            logBuffer += "[\(timestamp)] \(message)\n"
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard logFlushTask == nil else { return }
        logFlushTask = Task {
            await Self.logFlushDebounce()
            flush()
        }
    }

    // MARK: - Shared timing helpers
    // Shared by ScriptTab + AgentViewModel/Logging.swift so the terminal-drip and
    // log-debounce timings live in one place. Both callers had byte-identical sleeps;
    // routing them through these helpers keeps the cadence consistent.

    /// Whether the terminal drip-typing effect is on (HUD option). Default true.
    /// When off, drip loops dump pending text instantly.
    nonisolated static var dripEnabled: Bool {
        UserDefaults.standard.object(forKey: "dripEnabled") as? Bool ?? true
    }

    /// One char emission tick during the terminal drip animation.
    /// Reads `terminalSpeed` from UserDefaults; defaults to 22ms.
    nonisolated static func dripEmitTick() async {
        let speed = UserDefaults.standard.integer(forKey: "terminalSpeed")
        try? await Task.sleep(for: .milliseconds(speed > 0 ? speed : 22))
    }

    /// Idle tick while the drip task is waiting for more streamed chars (half speed, min 5ms).
    nonisolated static func dripIdleTick() async {
        let speed = UserDefaults.standard.integer(forKey: "terminalSpeed")
        try? await Task.sleep(for: .milliseconds(max(5, (speed > 0 ? speed : 22) / 2)))
    }

    /// 50ms debounce window for log-buffer flush — coalesces bursty appends.
    nonisolated static func logFlushDebounce() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Safety-valve cap for activityLog — applied at every mutation site.
    /// Large enough that a normal session never trims; ActivityLogView renders
    /// append-only so log size no longer drives per-flush cost.
    nonisolated static let logCap = 5_000_000

    /// Banner inserted when the log is trimmed; ActivityLogView styles it with a yellow background.
    nonisolated static let trimBanner = "··· earlier output trimmed ···\n\n"

    /// Unified activity-log cap: optionally drops oldest task sections, then
    /// enforces the byte cap. Always idempotent. Prepends `trimBanner` once.
    /// - Parameter keepRecentTasks: if set, keep only the last N task sections
    ///   (split by `AgentViewModel.newTaskMarker`). If nil, only byte cap applies.
    /// - Parameter cap: character cap (defaults to `logCap`).
    nonisolated static func capActivityLog(_ log: String, keepRecentTasks: Int? = nil, cap: Int = logCap) -> String {
        var result = log

        // Pass 1: task-count cap (when set). Drops oldest whole task sections.
        if let limit = keepRecentTasks, limit > 0 {
            let marker = AgentViewModel.newTaskMarker
            let parts = result.components(separatedBy: marker)
            // parts[0] is anything before the first marker; tasks live in parts[1...].
            if parts.count > limit + 1 {
                let kept = parts.suffix(limit).joined(separator: marker)
                result = marker + kept
            }
        }

        // Pass 2: byte cap. Snaps to next newline so we never start mid-line.
        // utf8.count is O(1) for native strings and >= character count, so the
        // common under-cap path never walks the string.
        guard result.utf8.count > cap, result.count > cap else { return result }
        let target = max(0, cap - trimBanner.count)
        var trimmed = String(result.dropFirst(result.count - target))
        if let nl = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: nl)...])
        }
        return trimBanner + trimmed
    }

    func flush() {
        logFlushTask?.cancel()
        logFlushTask = nil
        if !logBuffer.isEmpty {
            activityLog.append(logBuffer)
            activityLog = Self.capActivityLog(activityLog)
            logBuffer = ""
            NotificationCenter.default.post(name: .activityLogDidChange, object: id)
        }
    }

    // MARK: - LLM Streaming

    func appendStreamDelta(_ delta: String) {
        if !llmStreamingStarted {
            llmStreamingStarted = true
            llmStreamBuffer = ""
            rawLLMOutput = ""
            displayedLLMOutput = ""
            dripDisplayIndex = 0
        }
        rawLLMOutput += delta
        startDripIfNeeded()
    }

    /// Drip characters from rawLLMOutput into displayedLLMOutput for a terminal typing effect
    func startDripIfNeeded() {
        guard dripTask == nil else { return }
        dripTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Index by unicode scalars, not Characters: appending a delta can
                // merge grapheme clusters (e.g. ⚙ + U+FE0F), shifting Character
                // offsets and skipping the next char. Scalar offsets are stable
                // under append-only mutation.
                let scalars = self.rawLLMOutput.unicodeScalars
                let total = scalars.count
                if self.dripDisplayIndex < total {
                    // Drip off (HUD option): dump everything instantly.
                    if !Self.dripEnabled {
                        self.displayedLLMOutput = self.rawLLMOutput
                        self.dripDisplayIndex = total
                        await Self.dripIdleTick()
                        continue
                    }
                    // Adaptive chunk: 1 scalar per tick for the terminal feel,
                    // larger slices when a big backlog builds up — keeps the
                    // per-tick index walk from going O(n²) on long outputs.
                    let pending = total - self.dripDisplayIndex
                    let chunk = max(1, pending / 100)
                    let start = scalars.index(scalars.startIndex, offsetBy: self.dripDisplayIndex)
                    let end = scalars.index(start, offsetBy: chunk)
                    self.displayedLLMOutput.unicodeScalars.append(contentsOf: scalars[start..<end])
                    self.dripDisplayIndex += chunk
                    await Self.dripEmitTick()
                } else if self.llmStreamingStarted {
                    await Self.dripIdleTick()
                } else {
                    break
                }
            }
            self.dripTask = nil
        }
    }

    func flushStreamBuffer() {
        llmStreamFlushTask?.cancel()
        llmStreamFlushTask = nil
        // Stream text goes to LLM output only — not the activity log
        llmStreamBuffer = ""
        llmStreamingStarted = false
        // Let drip task finish naturally — no instant dump
    }

    private func scheduleLLMStreamFlush() {
        flushStreamBuffer()
    }

    func resetLLMStreamCounters() {
        streamLineCount = 0
    }

    // MARK: - Prompt History Navigation

    func addToHistory(_ prompt: String) {
        promptHistory.append(prompt)
        historyIndex = -1
        savedInput = ""
    }

    func navigateHistory(direction: Int) {
        guard !promptHistory.isEmpty else { return }

        if historyIndex == -1 {
            savedInput = taskInput
            if direction == -1 {
                historyIndex = promptHistory.count - 1
            } else {
                return
            }
        } else {
            historyIndex += direction
        }

        if historyIndex < 0 {
            historyIndex = -1
            taskInput = savedInput
            return
        }

        if historyIndex >= promptHistory.count {
            historyIndex = -1
            taskInput = savedInput
            return
        }

        taskInput = promptHistory[historyIndex]
    }
}
