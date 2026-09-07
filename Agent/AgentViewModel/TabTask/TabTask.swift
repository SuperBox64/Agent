
@preconcurrency import Foundation
import AgentTools
import AgentAudit
import AgentLLM
import AppKit
import AgentMCP
import AgentD1F


// MARK: - Tab Task Execution

extension AgentViewModel {

    /// Start an LLM task on a specific script tab.
    func runTabTask(tab: ScriptTab) {
        let typed = tab.taskInput.trimmingCharacters(in: .whitespaces)
        // Merge long-text attachments (captured via Cmd+V chips) into the prompt.
        let task = Self.mergePastedTexts(tab.pastedTexts, into: typed)
        tab.pastedTexts.removeAll()
        guard !task.isEmpty else { return }

        // Handle /memory in tab context
        if task.lowercased().hasPrefix("/memory") {
            tab.taskInput = ""
            let arg = task.dropFirst(7).trimmingCharacters(in: .whitespaces)
            if arg.isEmpty || arg.lowercased() == "show" {
                let content = MemoryStore.shared.content
                tab.appendLog("📝 Memory:\n\(content.isEmpty ? "(empty)" : content)")
            } else if arg.lowercased() == "clear" {
                MemoryStore.shared.write("")
                tab.appendLog("📝 Memory cleared.")
            } else if arg.lowercased() == "edit" {
                let url = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/AgentScript/memory.md")
                AppKit.NSWorkspace.shared.open(url)
                tab.appendLog("📝 Opened memory.md in editor.")
            } else {
                MemoryStore.shared.append(arg)
                tab.appendLog("📝 Added to memory: \(arg)")
            }
            tab.flush()
            return
        }

        // Handle /clear in tab context
        if task.lowercased() == "/clear" {
            tab.taskInput = ""
            tab.activityLog = ""
            tab.logBuffer = ""
            tab.logFlushTask?.cancel()
            tab.logFlushTask = nil
            tab.streamLineCount = 0
            persistScriptTabs()
            return
        }

        tab.addToHistory(task)
        tab.taskInput = ""

        // Queue if already running
        if tab.isLLMRunning {
            tab.taskQueue.append(task)
            tab.appendLog("📋 Queued (\(tab.taskQueue.count)): \(task)")
            tab.flush()
            return
        }

        startTabTask(tab: tab, prompt: task)
    }

    /// Start executing a task on a tab (not queued).
    private func startTabTask(tab: ScriptTab, prompt: String) {
        tab.currentTaskPrompt = prompt
        tab.runningLLMTask = Task {
            await executeTabTask(tab: tab, prompt: prompt)
            // When done, run next queued task
            if !tab.taskQueue.isEmpty && !tab.isCancelled {
                let next = tab.taskQueue.removeFirst()
                startTabTask(tab: tab, prompt: next)
            }
        }
    }

    /// Stop the LLM task running on a script tab and clear its queue.
    func stopTabTask(tab: ScriptTab) {
        let queueCount = tab.taskQueue.count
        tab.taskQueue.removeAll()
        tab.runningLLMTask?.cancel()
        tab.runningLLMTask = nil
        tab.isLLMRunning = false
        tab.isLLMThinking = false
        tab.currentTaskPrompt = ""
        tab.currentAppleAIPrompt = ""
        if queueCount > 0 {
            tab.appendLog("🚫 Cancelled. \(queueCount) queued task(s) cleared.")
        } else {
            tab.appendLog("🚫 Cancelled.")
        }
        tab.flush()
    }

    // MARK: - Tab Task Execution Loop

    func executeTabTask(tab: ScriptTab, prompt: String) async {
        tab.isLLMRunning = true
        tab.llmMessages = [] // Fresh conversation for each task
        // Reset elapsed timer at the task-start callsite (see executeTask
        // for the ThinkingIndicatorView .onChange race that this guards against).
        tab.taskStartDate = Date()
        tab._taskElapsedFrozen = 0
        // Auto-expand HUD for THIS tab's run start (not on tab switches)
        tab.thinkingExpanded = true
        tab.thinkingOutputExpanded = true
        tab.thinkingDismissed = false
        tab.toolSteps.removeAll() // Fresh Steps list for this task
        // Reset fallback chain so this run starts on the primary provider
        FallbackChainService.shared.reset()
        // Tier 8: edits in this task must be preceded by a read in this task.
        Self.clearEditGateForTab(tabID: tab.id)
        Self.resetEditCycleTracking()
        if let stale = GoalStateStore.shared.clearIfStale() {
            tab.appendLog("🎯 Cleared stale goal (untouched >24h): \(stale.prefix(60))")
        }
        await HooksService.shared.runEventHooks(.taskStart, context: [
            "prompt": prompt,
            "tab": tab.displayTitle,
            "projectFolder": projectFolder
        ])

        var commandsRun: [String] = []
        criticReviewDone = false
        completionGateRefusals = 0
        var completionSummary = ""
        // Guard counters — shared with the main loop's overnight-coding battery
        // (Guards.swift) so tab tasks get the same nudges and failure budget.
        var consecutiveBuildFailures = 0
        var unbuiltEditCount = 0

        // Clear LLM Output for new task — show blinking cursor
        tab.dripTask?.cancel(); tab.dripTask = nil
        tab.rawLLMOutput = ""
        tab.displayedLLMOutput = ""
        tab.dripDisplayIndex = 0

        tab.appendLog(AgentViewModel.newTaskMarker)
        tab.appendLog("👤 \(prompt)")
        tab.flush()

        // Triage: direct commands, Apple AI, accessibility, or pass through.
        var directCommandContext: String?
        let triageOutcome = await runTabTaskTriage(
            tab: tab, prompt: prompt, completionSummary: &completionSummary
        )
        switch triageOutcome {
        case .done:
            return
        case .passThrough:
            break
        case .llmWithContext(let ctx):
            directCommandContext = ctx
        }

        let tabHistoryContext = buildTabHistoryContext(tab: tab)

        // Use tab's project folder if set, otherwise fall back to main project folder
        // Resolve to directory (strip filename if path points to a file like .xcodeproj)
        let rawFolder = tab.projectFolder.isEmpty ? self.projectFolder : tab.projectFolder
        let projectFolder = Self.resolvedWorkingDirectory(rawFolder)

        var (provider, modelId) = resolvedLLMConfig(for: tab)
        tab.appendLog("🧠 \(provider.displayName) / \(modelId)")
        tab.flush()

        var mt = maxTokens
        var services = buildTabLLMServices(
            provider: provider,
            modelId: modelId,
            historyContext: tabHistoryContext,
            projectFolder: projectFolder,
            maxTokens: mt
        )

        var messages = buildTabInitialMessages(
            tab: tab,
            prompt: prompt,
            projectFolder: projectFolder,
            directCommandContext: directCommandContext
        )

        // No mode filtering — every user-enabled tool is sent on every turn.
        // ToolPreferencesService is the only tool filter.
        let activeGroups: Set<String>? = nil

        var iterations = 0
        var textOnlyCount = 0
        var timeoutRetryCount = 0
        var stopRouteRetries = 0
        var compactionState = CompactionState(contextWindow: contextWindow(for: provider), maxTokens: mt)
        var stuckFiles: [String: Int] = [:] // Edit failure count per file (for nudge)
        var repeatedCalls: [String: Int] = [:] // Identical tool-call fingerprint counts (broken-record guard)
        // Plan-mode enforcement state
        var filesEditedThisTask: Set<String> = []
        // Full system prompt + full tool descriptions on every turn — no condensed prompt, no compactTools, no mode
        // auto-switching. The LLM always sees the complete context and the complete tool list (filtered only by the user's UI toggles in ToolPreferencesService).

        mainLoop: while !Task.isCancelled {
            iterations += 1

            // Iteration cap — force task_complete when the LLM refuses to end.
            // Two final turns after the nudge (provider-agnostic — every provider
            // routes through this loop): one to finish the in-flight edit, one to
            // write the handoff doc. Hard stop at maxIterations + 1.
            if iterations == maxIterations {
                tab.appendLog("⏱ Iteration \(iterations)/\(maxIterations) — nudging LLM to wrap up (2 turns left)")
                tab.flush()
                messages.append([
                    "role": "user",
                    "content": "You have reached the iteration limit. You have TWO final turns. Turn 1: make ONE tool call to finish any in-flight edit. Turn 2: make ONE tool call to write a status/handoff document (e.g. STATUS.md) describing what is done and what remains, then call task_complete with a summary. Do not start any new work."
                ])
            } else if iterations == maxIterations + 1 {
                tab.appendLog("⏱ Iteration \(iterations)/\(maxIterations) — final turn")
                tab.flush()
                messages.append([
                    "role": "user",
                    "content": "This is your FINAL turn. Make ONE last tool call to write your status/handoff document, then call task_complete with a summary of what you accomplished and what remains."
                ])
            }
            if iterations > maxIterations + 1 {
                let summary = completionSummary.isEmpty
                    ? (commandsRun.isEmpty ? "(no actions — iteration cap reached)" : "Forced completion after \(iterations - 1) iterations. Last actions: \(commandsRun.suffix(5).joined(separator: ", "))")
                    : completionSummary
                completionSummary = summary
                tab.appendLog("⏱ Forced task_complete — hit iteration cap (\(maxIterations) + 2 wrap-up turns)")
                tab.appendLog("✅ Completed: \(summary)")
                tab.flush()
                break mainLoop
            }

            // Mode auto-switching removed: every user-enabled tool is available on
            // every turn. ToolPreferencesService UI toggles are the only filter.

            // Token-aware compaction — mutations happen only at threshold events so
            // the request prefix stays byte-stable and provider prompt caches hit.
            if iterations > 1 {
                // Async context-window fetches can land after task start — pick
                // up the real threshold instead of a possibly-stale 32K fallback.
                compactionState.refreshThreshold(contextWindow: contextWindow(for: provider))
                let compactLog: (String) -> Void = { [weak tab] msg in
                    tab?.appendLog(msg)
                    tab?.flush()
                }
                let bundle = LLMServiceBundle(
                    claude: services.claude, codex: nil,
                    openAICompatible: services.openAICompatible,
                    ollama: services.ollama, foundationModel: services.foundationModel
                )
                let compacted = await Self.tieredCompact(
                    &messages,
                    state: &compactionState,
                    summarizer: makeCompactSummarizer(services: bundle, log: compactLog),
                    log: compactLog
                )
                if compacted, let restored = postCompactReattachment(tabID: tab.id) {
                    Self.appendUserText(restored, to: &messages)
                    compactLog("🗂️ Re-attached goal/plan/edited files after compaction (\(restored.count) chars)")
                }
            }

            do {
                tab.isLLMThinking = true
                // Only auto-show overlay on the FIRST iteration. Respect manual dismiss (Cmd+B).
                if iterations == 1 { tab.thinkingDismissed = false }
                // Surface any rate-limit backoff — enforce() sleeps silently inside
                // the service, which users perceive as the app hanging.
                let limiterKey = services.claude != nil
                    ? APIProvider.claude.rawValue : provider.rawValue
                let backoff = await LLMRateLimiter.shared.pendingWait(provider: limiterKey)
                if backoff >= 1 {
                    tab.appendLog("⏳ Rate-limit backoff — waiting \(Int(backoff.rounded()))s before request")
                    tab.flush()
                }
                let response: (content: [[String: Any]], stopReason: String, inputTokens: Int, outputTokens: Int)
                let streamStart = CFAbsoluteTimeGetCurrent()
                // Append-only between compaction events — see tieredCompact above.
                let sendMessages = messages
                if let claude = services.claude {
                    response = try await claude.sendStreaming(messages: sendMessages, activeGroups: activeGroups) { [weak tab] delta in
                        Task { @MainActor in
                            tab?.isLLMThinking = false
                            tab?.appendStreamDelta(delta)
                        }
                    }

                    tab.flushStreamBuffer()
                } else if let openAICompatible = services.openAICompatible {
                    let r = try await openAICompatible
                        .sendStreaming(messages: sendMessages, activeGroups: activeGroups) { [weak tab] delta in
                            Task { @MainActor in
                                tab?.isLLMThinking = false
                                tab?.appendStreamDelta(delta)
                            }
                        }
                    response = (r.content, r.stopReason, r.inputTokens, r.outputTokens)

                    tab.flushStreamBuffer()
                } else if let ollama = services.ollama {
                    let r = try await ollama.sendStreaming(messages: sendMessages, activeGroups: activeGroups) { [weak tab] delta in
                        Task { @MainActor in
                            tab?.isLLMThinking = false
                            tab?.appendStreamDelta(delta)
                        }
                    }
                    response = (r.content, r.stopReason, r.inputTokens, r.outputTokens)

                    tab.flushStreamBuffer()
                } else if let foundationModelService = services.foundationModel {
                    let r = try await foundationModelService.sendStreaming(messages: sendMessages) { [weak tab] delta in
                        Task { @MainActor in
                            tab?.isLLMThinking = false
                            tab?.appendStreamDelta(delta)
                        }
                    }
                    response = (r.content, r.stopReason, 0, 0)

                    tab.flushStreamBuffer()
                } else {
                    throw AgentError.noAPIKey
                }
                // Strip done/task_complete from LLM Output
                Self.stripCompletionText(&tab.rawLLMOutput)
                // Wait for drip to finish
                await tab.dripTask?.value
                if !tab.rawLLMOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tab.displayedLLMOutput = tab.rawLLMOutput
                    tab.dripDisplayIndex = tab.rawLLMOutput.unicodeScalars.count
                }
                compactionState.recordUsage(inputTokens: response.inputTokens, messageCount: sendMessages.count)
                // Track token usage — use reported counts or estimate from text (~4 chars/token)
                let inTok = response.inputTokens > 0 ? response.inputTokens : Self.estimateTokens(messages: messages)
                let outTok = response.outputTokens > 0 ? response.outputTokens : Self.estimateTokens(content: response.content)
                taskInputTokens += inTok
                taskOutputTokens += outTok
                sessionInputTokens += inTok
                sessionOutputTokens += outTok
                TokenUsageStore.shared.record(inputTokens: inTok, outputTokens: outTok)
                TokenUsageStore.shared.recordModelUsage(
                    model: modelId, input: inTok, output: outTok, provider: provider.displayName,
                    tabId: tab.id, tabLabel: tab.displayTitle,
                    subscriptionBilled: Self.isSubscriptionCredential(provider: provider, apiKey: apiKey)
                )
                FallbackChainService.shared.recordSuccess()
                let streamElapsed = CFAbsoluteTimeGetCurrent() - streamStart
                tab.lastElapsed = streamElapsed
                tab.tabInputTokens += inTok
                tab.tabOutputTokens += outTok
                // Show timing in activity log so user can see what's slow
                tab.appendLog("🕐 LLM \(String(format: "%.1f", streamElapsed))s | stop: \(response.stopReason) | iter \(iterations)")
                tab.flush()
                tab.isLLMThinking = false
                timeoutRetryCount = 0 // Reset on successful response
                guard !Task.isCancelled else { break }

                // Process the response's tool_use blocks (extracted helper).
                let outcome = await processTabResponseContent(
                    tab: tab,
                    content: response.content,
                    commandsRun: &commandsRun,
                    stuckFiles: &stuckFiles,
                    repeatedCalls: &repeatedCalls,
                    filesEditedThisTask: &filesEditedThisTask,
                    completionSummary: &completionSummary,
                    unbuiltEditCount: &unbuiltEditCount,
                    consecutiveBuildFailures: &consecutiveBuildFailures
                )

                switch outcome {
                case .complete(let summary):
                    completionSummary = summary
                    tab.llmMessages = messages
                    // Save task history for tab
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss"
                    let time = formatter.string(from: Date())
                    tab.tabTaskSummaries.append("[\(time)] \(prompt) → \(completionSummary)")
                    history.add(
                        TaskRecord(prompt: prompt, summary: completionSummary, commandsRun: commandsRun),
                        maxBeforeSummary: maxHistoryBeforeSummary, apiKey: apiKey,
                        model: modelId
                    )
                    tab.isLLMRunning = false
                    tab.isLLMThinking = false
                    await HooksService.shared.runEventHooks(.taskComplete, context: [
                        "prompt": prompt,
                        "summary": completionSummary,
                        "tab": tab.displayTitle,
                        "projectFolder": projectFolder
                    ])
                    return
                case .normal(let hasToolUse, let toolResults):
                    // stop_reason-driven loop control — same routing as the main
                    // loop. Goal criteria are main-task-scoped, so pass none here.
                    let routeText = response.content.compactMap { $0["text"] as? String }.joined()
                    let route = Self.routeStopReason(
                        stopReason: response.stopReason,
                        hasToolUse: hasToolUse,
                        hasPendingTools: !toolResults.isEmpty,
                        responseText: routeText,
                        openCriteria: [],
                        retriesUsed: stopRouteRetries
                    )
                    if case .retry(let correction, let logLine) = route {
                        stopRouteRetries += 1
                        tab.appendLog(logLine)
                        tab.flush()
                        let keepTypes: Set<String> = ["text", "thinking", "redacted_thinking"]
                        let textBlocks = response.content.filter { keepTypes.contains($0["type"] as? String ?? "") }
                        messages.append([
                            "role": "assistant",
                            "content": textBlocks.isEmpty ? "(empty response)" : textBlocks
                        ])
                        messages.append(["role": "user", "content": correction])
                        tab.llmMessages = messages
                        continue mainLoop
                    }

                    messages.append(["role": "assistant", "content": response.content])
                    tab.llmMessages = messages

                    if hasToolUse && !toolResults.isEmpty {
                        messages.append(["role": "user", "content": toolResults])
                        tab.llmMessages = messages
                    } else {
                        // No tool_use at all, OR tool_use blocks that produced no
                        // results (server-side tools only). Both are effectively a
                        // text-only turn and get the same treatment. The old separate
                        // branch for the second case ended the task on bare
                        // substrings ("task is complete", "task_complete", …) with
                        // completionSummary = "Done" — and left the transcript ending
                        // on an assistant turn.
                        //
                        // Check if model wrote task_complete as text instead of a tool call.
                        // Only a fully-formed `task_complete(summary: "…")` / `done(summary: "…")`
                        // counts — a bare mention of the word is narration and falls
                        // through to the text-only nudge below.
                        let responseText = response.content.compactMap { $0["text"] as? String }.joined()
                        if let match = responseText.range(
                            of: #"(?:task_complete|done)\(summary[=:]\s*"([^"]+)""#,
                            options: .regularExpression
                        ) {
                            let raw = String(responseText[match])
                            completionSummary = raw
                                .replacingOccurrences(
                                    of: #"(?:task_complete|done)\(summary[=:]\s*""#,
                                    with: "",
                                    options: .regularExpression
                                )
                                .replacingOccurrences(of: "\"", with: "")
                            tab.appendLog("✅ Completed: \(completionSummary)")
                            tab.flush()
                            break mainLoop
                        }
                        // LLM responded with text only — nudge it to continue or finish
                        textOnlyCount += 1
                        if textOnlyCount >= 3 {
                            if !responseText.isEmpty { completionSummary = String(responseText.prefix(500)) }
                            break mainLoop
                        }
                        messages.append([
                            "role": "user",
                            "content": "Continue with the next step. When you are completely done, call task_complete(summary: \"...\")."
                        ])
                    }
                }

            } catch {
                let active: ActiveLLMService
                if services.claude != nil { active = .claude }
                else if services.openAICompatible != nil { active = .openAICompatible }
                else if services.ollama != nil { active = .ollama }
                else if services.foundationModel != nil { active = .foundationModel }
                else { active = .none }
                let outcome = await handleTaskLoopError(
                    error,
                    activeService: active,
                    providerDisplayName: provider.displayName,
                    messages: &messages,
                    timeoutRetryCount: &timeoutRetryCount,
                    maxTimeoutRetries: maxRetries,
                    appendLogFn: { [weak tab] s in tab?.appendLog(s) },
                    flushFn: { [weak tab] in tab?.flush() }
                )
                switch outcome {
                case .continueLoop:
                    continue
                case .breakLoop:
                    break mainLoop
                case .lowerMaxTokens(let newMT):
                    // Tier 10.3: same transcript, smaller output budget.
                    mt = newMT
                    compactionState.maxTokens = mt
                    compactionState.refreshThreshold(contextWindow: contextWindow(for: provider))
                    services = buildTabLLMServices(
                        provider: provider,
                        modelId: modelId,
                        historyContext: tabHistoryContext,
                        projectFolder: projectFolder,
                        maxTokens: mt
                    )
                    continue
                case .fallbackRequested(let fbProvider, let fbModel, _):
                    provider = fbProvider
                    modelId = fbModel
                    // Rescale the compaction threshold to the fallback provider's
                    // real context window (see the main loop's fallback path).
                    compactionState = CompactionState(contextWindow: contextWindow(for: fbProvider), maxTokens: mt)
                    services = buildTabLLMServices(
                        provider: provider,
                        modelId: modelId,
                        historyContext: tabHistoryContext,
                        projectFolder: projectFolder,
                        maxTokens: mt
                    )
                    tab.appendLog("✅ Now using \(provider.displayName) / \(modelId)")
                    tab.flush()
                    timeoutRetryCount = 0
                    continue
                }
            }
        }


        // Save task history if task didn't call task_complete
        if completionSummary.isEmpty {
            let summary = Task.isCancelled ? "(cancelled)" : commandsRun.isEmpty ? "(no actions)" : "(incomplete)"
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let time = formatter.string(from: Date())
            tab.tabTaskSummaries.append("[\(time)] \(prompt) → \(summary)")
            history.add(
                TaskRecord(prompt: prompt, summary: summary, commandsRun: commandsRun),
                maxBeforeSummary: maxHistoryBeforeSummary,
                apiKey: apiKey,
                model: selectedModel
            )
        }

        // If Messages tab task ended without task_complete, still send a reply
        if tab.isMessagesTab, let handle = tab.replyHandle {
            tab.replyHandle = nil
            let reply = completionSummary.isEmpty
                ? (Task.isCancelled ? "(cancelled)" : "Done")
                : completionSummary
            sendMessagesTabReply(reply, handle: handle)
        }

        tab.flush()
        tab.isLLMRunning = false
        tab.isLLMThinking = false
        // Persist HUD state (LLM output, Steps, tokens, elapsed) NOW — the
        // willTerminate hook is not reliable (app may be killed by a build/relaunch).
        persistScriptTabs()
    }

    // MARK: - Tab Tool Call Handler

    struct TabToolResult {
        let toolResult: [String: Any]?
        let isComplete: Bool
    }

    /// Dispatch tab tool calls — handler bodies in AgentViewModel+TabToolHandlers.swift
    func handleTabToolCall(
        tab: ScriptTab, name: String, input: [String: Any], toolId: String
    ) async -> TabToolResult {
        let rawDetail = input["path"] as? String
            ?? input["file_path"] as? String
            ?? input["command"] as? String
            ?? input["action"] as? String
            ?? ""
        let detail = (rawDetail as NSString).lastPathComponent.isEmpty
            ? rawDetail
            : (rawDetail as NSString).lastPathComponent
        let stepId = tab.recordToolStep(name: name, detail: detail)
        let result = await handleTabToolCallBody(tab: tab, name: name, input: input, toolId: toolId)
        let status: AgentViewModel.ToolStep.Status = Self.toolResultLooksLikeError(result.toolResult) ? .error : .success
        tab.completeToolStep(id: stepId, status: status)
        persistScriptTabs() // Keep the Steps list on disk even if the app is killed mid-task
        return result
    }

    /// Heuristic: inspect the tool_result content for signals that the tool failed.
    /// Used to mark Steps red when a shell/edit/etc. tool returned an error payload.
    private static func toolResultLooksLikeError(_ toolResult: [String: Any]?) -> Bool {
        guard let content = toolResult?["content"] as? String else { return false }
        let lower = content.lowercased()
        // Non-zero exit codes — match "exit code: 1", "exit code: 127", etc.
        if let range = lower.range(of: "exit code: ") {
            let tail = lower[range.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            if let n = Int(digits), n != 0 { return true }
        }
        // JSON-shaped failures from native tool handlers, e.g.
        //   {"success": false, "error": "Unknown action: ..."}
        if lower.contains("\"success\": false") || lower.contains("\"success\":false") { return true }
        if lower.contains("\"error\":") || lower.contains("\"error\" :") { return true }
        // Plain-text error phrases emitted by shell/file tools
        let markers = ["❌", "error: ", "\nerror: ", "no such file", "command not found",
                       "permission denied", "operation not permitted", "failed: ",
                       "unknown action", "invalid action"]
        return markers.contains { lower.contains($0) }
    }

    // MARK: - Tab Command Execution

    /// Execute a command via UserService with cd prefix to ensure correct directory.
    /// Falls back to in-process execution when working directory is TCC-protected.
    func executeForTab(command: String, projectFolder pf: String = "") async -> (status: Int32, output: String) {
        // Fallback chain: passed projectFolder → self.projectFolder → home (handled by UserService)
        let folder = pf.isEmpty ? self.projectFolder : pf
        let dir = folder.isEmpty ? "" : Self.resolvedWorkingDirectory(folder)
        let fullCommand = Self.prependWorkingDirectory(command, projectFolder: dir)
        // TCC-protected folders must run in-process
        if Self.isTCCProtectedPath(dir) || Self.needsTCCPermissions(command) {
            return await Self.executeTCC(command: fullCommand)
        }
        return await userService.execute(command: fullCommand, workingDirectory: dir)
    }
}
