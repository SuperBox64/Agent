
@preconcurrency import Foundation
import AgentTools
import AgentMCP
import AgentD1F
import AgentSwift
import AgentAccess
import Cocoa


// MARK: - Task Execution Loop

extension AgentViewModel {

    func executeTask(_ rawPrompt: String) async {
        // Strip ! or !apple prefix (bypasses Apple AI triage)
        var prompt = rawPrompt
        if prompt.hasPrefix("\u{F8FF}") {
            prompt = String(prompt.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else if prompt.lowercased().hasPrefix("!apple ") {
            prompt = String(prompt.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        isRunning = true
        userWasActive = false
        rootWasActive = false
        // Reset elapsed timer at the task-start callsite. Pinning this to a
        // ThinkingIndicatorView .onChange was fragile — if the view wasn't
        // mounted on the false→true transition, the timer kept the prior
        // task's frozen value (showed 4h+ on a fresh task).
        mainTaskStartDate = Date()
        _mainTaskElapsedFrozen = 0
        // Auto-expand HUD for the main tab's run start (not on tab switches)
        thinkingExpanded = true
        thinkingOutputExpanded = true
        thinkingDismissed = false
        recentOutputHashes.removeAll()
        toolSteps.removeAll()
        DiffStore.shared.clear()

        // Start progress updates for iMessage requests (every 10 minutes)
        if agentReplyHandle != nil {
            startProgressUpdates(for: prompt)
        }

        // Clear LLM Output for new task — show blinking cursor
        dripTask?.cancel(); dripTask = nil
        rawLLMOutput = ""
        displayedLLMOutput = ""
        dripDisplayIndex = 0

        activityLog = ScriptTab.capActivityLog(activityLog, keepRecentTasks: visibleTaskCount)
        taskInputTokens = 0
        taskOutputTokens = 0
        budgetUsedFraction = 0
        subAgents.removeAll()
        FileBackupService.shared.clearTaskSnapshots()
        TokenUsageStore.shared.resetTaskMetrics()
        SessionStore.shared.newSession()
        FallbackChainService.shared.reset()
        ToolOutcomeStore.shared.startTask(projectFolder: projectFolder)
        if let stale = GoalStateStore.shared.clearIfStale() {
            appendLog("🎯 Cleared stale goal (untouched >24h): \(stale.prefix(60))")
        }
        Self.clearToolCache()
        Self.resetEditCycleTracking()
        // Tier 8: edits in this task must be preceded by a read in this task.
        Self.clearEditGateForTab(tabID: Self.mainTabID)
        // No mode filtering — send every user-enabled tool on every turn.
        // The LLM picks what it needs; ToolPreferencesService is the only filter.
        let activeGroups: Set<String>? = nil
        let isXcode = Self.isXcodeProject(projectFolder)
        appendLog(Self.newTaskMarker)
        appendLog("👤 \(prompt)")
        flushLog()

        // Use ChatHistoryStore for LLM context (summaries for older tasks, full messages for recent)
        let historyContext = ChatHistoryStore.shared.buildLLMContext()
        var (provider, modelName, isVision) = resolveInitialProviderConfig()
        // Defer the "🧠 provider/model" log line until AFTER triage has run and we know we're actually going to the
        // cloud LLM. Logging it up-front (the previous behavior) made the activity log misleading when Apple AI handled the request locally — users saw both "🧠 Z.ai/glm-5.1" and "🍎 Opened Photo Booth and took a photo" for the same task even though the cloud LLM never ran.
        let displayModel = modelDisplayName(provider: provider, modelId: modelName)
        let apiURL = chatURLForProvider(provider)
        let isCoding = apiURL.contains("/coding/")
        let cloudModelLogLine = "🧠 \(provider.displayName) / \(displayModel)\(isCoding ? " (code)" : "")\(isVision ? " (vision)" : "")"

        var mt = maxTokens
        var services = buildLLMServiceBundle(
            provider: provider,
            modelName: modelName,
            isVision: isVision,
            historyContext: historyContext,
            maxTokens: mt
        )

        // Carry over prior-task messages so the session continues across Escape/new-prompt boundaries.
        // Sanitizer drops orphaned tool_use blocks and trailing assistant turns so Anthropic accepts the request.
        var messages: [[String: Any]] = Self.sanitizeMessagesForContinuation(lastTaskMessages)
        // Tier 7.6: a transcript idle for over an hour has a cold prompt cache —
        // clear old tool results (recoverable via restore_tool_result) up front.
        if Self.microcompactIfStale(&messages, lastActivity: lastTaskMessagesDate) {
            appendLog("🗜️ Continuation idle >60 min — cleared old tool results before first request")
        }
        defer { lastTaskMessages = messages; lastTaskMessagesDate = Date() }

        let effectivePrompt = Self.newTaskPrefix(projectFolder: projectFolder, prompt: prompt) + prompt

        let hadAttachments = !attachedImagesBase64.isEmpty
        taskScopeImages = attachedImages
        if hadAttachments {
            appendLog("(\(attachedImagesBase64.count) screenshot(s) attached)")
            var contentBlocks: [[String: Any]] = attachedImagesBase64.map { base64 in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": base64
                    ] as [String: Any]
                ]
            }
            contentBlocks.append(["type": "text", "text": effectivePrompt])
            messages.append(["role": "user", "content": contentBlocks])
            // Clear attachments after use
            attachedImages.removeAll()
            attachedImagesBase64.removeAll()
        } else {
            messages.append(["role": "user", "content": effectivePrompt])
        }

        commandsRun = []
        criticReviewDone = false
        completionGateRefusals = 0
        var completionSummary = ""
        var stopRouteRetries = 0
        // Tier 10.1: output truncation has its own recovery ladder — one
        // same-request retry with a bigger budget, then ≤3 continuations.
        var maxTokensRetries = 0
        var maxTokensEscalated = false
        // Tier 10.4: iteration of the last goal_state call or goal reminder.
        var lastGoalActivity = 0
        // Tier 10.5: cache-warmth note for ≥1M windows, sent once per task.
        var cacheWarmthSent = false
        var timeoutRetryCount = 0
        let maxTimeoutRetries = maxRetries

        // Apple Intelligence mediator for contextual annotations
        let mediator = AppleIntelligenceMediator.shared
        var appleAIAnnotations: [AppleIntelligenceMediator.Annotation] = []

        // ! or !apple prefix bypasses Apple AI triage — sends prompt straight to cloud LLM.
        let appleBypass = rawPrompt.hasPrefix("\u{F8FF}")
            || rawPrompt.lowercased().hasPrefix("!apple ")
            || hadAttachments
        if appleBypass {
            appendLog(cloudModelLogLine)
            flushLog()
        } else {
            // Triage: Apple AI answers greetings on-device, or passes through to the cloud LLM.
            let triageResult = await mediator.triagePrompt(prompt, appendLog: { [weak self] msg in self?.appendLog(msg) })
            let triageOutcome = await handleTriageOutcome(
                triageResult,
                prompt: prompt,
                cloudModelLogLine: cloudModelLogLine,
                messages: &messages,
                completionSummary: &completionSummary
            )
            if case .completed = triageOutcome { return }
        }

        // Apple Intelligence context injection removed — was confusing LLMs at task start
        // Apple AI still runs on task_complete to summarize results for the user

        var iterations = 0
        // Token budget tracker — detects diminishing returns and prevents runaway costs
        var budgetTracker = TokenBudgetTracker(ceiling: tokenBudgetCeiling)
        // Context compaction state — token-aware triggers with circuit breaker
        var compactionState = CompactionState(contextWindow: contextWindow(for: provider), maxTokens: mt)
        // Overnight coding guards
        var unbuiltEditCount = 0 // build enforcement — nudge after edit without build
        var consecutiveBuildFailures = 0 // error budget — stop after 5
        var stuckFiles: [String: Int] = [:] // stuck detection — skip after 5 failures per file
        var textOnlyNudges = 0 // silent-completion guard — nudge once before accepting a tool-less turn
        // Full system prompt + full tool descriptions on every turn. The earlier condensed-prompt + compactTools
        // optimization saved ~4K tokens/turn but the user prefers the LLM having maximum context every iteration over the savings.
        let userName = NSFullUserName()
        let userHome = NSHomeDirectory()
        _ = userName; _ = userHome // kept for any future per-task prompt customization
        // Track unique files edited (write_file/edit_file/diff_apply/create_diff/apply_diff) for plan-mode enforcement
        var filesEditedThisTask: Set<String> = []

        taskLoop: while !Task.isCancelled {
            iterations += 1

            // Iteration cap — the LLM can loop forever calling tools without ever
            // invoking task_complete (common with smaller/local models). Two final
            // turns after the nudge (provider-agnostic — every provider routes
            // through this loop): one to finish the in-flight edit, one to write
            // the handoff doc. Hard stop at maxIterations + 1.
            if iterations == maxIterations {
                appendLog("⏱ Iteration \(iterations)/\(maxIterations) — nudging LLM to wrap up (2 turns left)")
                flushLog()
                messages.append([
                    "role": "user",
                    "content": "You have reached the iteration limit. You have TWO final turns. Turn 1: make ONE tool call to finish any in-flight edit. Turn 2: make ONE tool call to write a status/handoff document (e.g. STATUS.md) describing what is done and what remains, then call task_complete with a summary. Do not start any new work."
                ])
            } else if iterations == maxIterations + 1 {
                appendLog("⏱ Iteration \(iterations)/\(maxIterations) — final turn")
                flushLog()
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
                appendLog("⏱ Forced task_complete — hit iteration cap (\(maxIterations) + 2 wrap-up turns)")
                appendLog("✅ Completed: \(summary)")
                flushLog()
                break taskLoop
            }

            // No prompt tiering and no mode auto-switching: every turn sends the full system prompt with full tool
            // descriptions, filtered only by the user's UI toggles in ToolPreferencesService.

            // Token-aware context compaction — replaces fixed iteration-based triggers
            if iterations > 1 {
                // Async context-window fetches can land after task start — pick
                // up the real threshold instead of a possibly-stale 32K fallback.
                compactionState.refreshThreshold(contextWindow: contextWindow(for: provider))
                let compactLog: (String) -> Void = { [weak self] msg in
                    self?.appendLog(msg)
                    self?.flushLog()
                }
                let compacted = await Self.tieredCompact(
                    &messages,
                    state: &compactionState,
                    summarizer: makeCompactSummarizer(services: services, log: compactLog),
                    log: compactLog
                )
                // Re-attach what the summary can't carry verbatim: open goal
                // criteria, the plan checklist, and the current on-disk content
                // of files edited this task. Lives in the frozen prefix.
                if compacted, let restored = postCompactReattachment(tabID: Self.mainTabID) {
                    Self.appendUserText(restored, to: &messages)
                    compactLog("🗂️ Re-attached goal/plan/edited files after compaction (\(restored.count) chars)")
                }
            }

            do {
                isThinking = true
                // Only auto-show overlay on the FIRST iteration. Subsequent iterations
                // must respect the user's manual dismiss (Cmd+B during a running task).
                if iterations == 1 { thinkingDismissed = false }
                // Surface any rate-limit backoff — enforce() sleeps silently inside
                // the service, which users perceive as the app hanging.
                let limiterKey = services.claude != nil
                    ? APIProvider.claude.rawValue : provider.rawValue
                let backoff = await LLMRateLimiter.shared.pendingWait(provider: limiterKey)
                if backoff >= 1 {
                    appendLog("⏳ Rate-limit backoff — waiting \(Int(backoff.rounded()))s before request")
                    flushLog()
                }

                // Append-only between compaction events — per-turn rewriting broke
                // provider prompt-cache prefix stability. tieredCompact (above) is the
                // only place messages mutate, and only past the token threshold.
                let sendMessages = messages

                let response: (content: [[String: Any]], stopReason: String, inputTokens: Int, outputTokens: Int)
                // Tier 9.3: read-only tool_use blocks start executing the
                // moment they finish streaming; results are consumed below.
                let streamPrefetch = Self.StreamPrefetch()
                flushLog()
                if let claude = services.claude {
                    let prefetchPF = projectFolder
                    let prefetchTab = selectedTabId ?? Self.mainTabID
                    response = try await claude.sendStreaming(
                        messages: sendMessages,
                        activeGroups: activeGroups,
                        onToolUse: { id, name, json in
                            streamPrefetch.start(toolId: id, name: name, inputJSON: json,
                                                 projectFolder: prefetchPF, tabID: prefetchTab)
                        }
                    ) { [weak self] delta in
                        Task { @MainActor in
                            self?.isThinking = false
                            self?.appendStreamDelta(delta)
                        }
                    }

                } else if let codex = services.codex {
                    let r = try await codex.sendStreaming(messages: sendMessages, activeGroups: activeGroups) { [weak self] delta in
                        Task { @MainActor in
                            self?.isThinking = false
                            self?.appendStreamDelta(delta)
                        }
                    }
                    response = (r.content, r.stopReason, r.inputTokens, r.outputTokens)

                } else if let openAICompatible = services.openAICompatible {
                    let r = try await openAICompatible
                        .sendStreaming(messages: sendMessages, activeGroups: activeGroups) { [weak self] delta in
                            Task { @MainActor in
                                self?.isThinking = false
                                self?.appendStreamDelta(delta)
                            }
                        }
                    response = (r.content, r.stopReason, r.inputTokens, r.outputTokens)

                } else if let ollama = services.ollama {
                    let r = try await ollama.sendStreaming(messages: sendMessages, activeGroups: activeGroups) { [weak self] delta in
                        Task { @MainActor in
                            self?.isThinking = false
                            self?.appendStreamDelta(delta)
                        }
                    }
                    response = (r.content, r.stopReason, r.inputTokens, r.outputTokens)

                } else if let foundationModelService = services.foundationModel {
                    let r = try await foundationModelService.sendStreaming(messages: sendMessages) { [weak self] delta in
                        Task { @MainActor in
                            self?.isThinking = false
                            self?.appendStreamDelta(delta)
                        }
                    }
                    response = (r.content, r.stopReason, 0, 0)

                } else {
                    throw AgentError.noAPIKey
                }
                // Real input_tokens drive the compaction trigger (Tier 7.2) —
                // they include the system prompt + tool schemas the estimate can't see.
                compactionState.recordUsage(inputTokens: response.inputTokens, messageCount: sendMessages.count)
                // Track token usage — use reported counts or estimate from text (~4 chars/token)
                let inTok = response.inputTokens > 0 ? response.inputTokens : Self.estimateTokens(messages: messages)
                let outTok = response.outputTokens > 0 ? response.outputTokens : Self.estimateTokens(content: response.content)
                taskInputTokens += inTok
                taskOutputTokens += outTok
                sessionInputTokens += inTok
                sessionOutputTokens += outTok
                TokenUsageStore.shared.record(inputTokens: inTok, outputTokens: outTok)
                budgetTracker.recordTurn(inputTokens: inTok, outputTokens: outTok)
                budgetUsedFraction = budgetTracker.usedFraction
                TokenUsageStore.shared.recordModelUsage(
                    model: modelName, input: inTok, output: outTok, provider: provider.displayName,
                    tabId: TokenUsageStore.mainTabKey, tabLabel: "Main",
                    subscriptionBilled: Self.isSubscriptionCredential(provider: provider, apiKey: apiKey)
                )
                FallbackChainService.shared.recordSuccess()
                flushStreamBuffer()
                isThinking = false
                timeoutRetryCount = 0 // Reset on successful response
                // Strip done/task_complete from LLM Output
                Self.stripCompletionText(&rawLLMOutput)
                // Wait for drip to finish
                await dripTask?.value
                if !rawLLMOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    displayedLLMOutput = rawLLMOutput
                    dripDisplayIndex = rawLLMOutput.unicodeScalars.count
                }
                guard !Task.isCancelled else { break }

                var toolResults: [[String: Any]] = []
                let parseResult = await parseLLMResponseContent(
                    response.content,
                    prompt: prompt,
                    mediator: mediator,
                    appleAIAnnotations: &appleAIAnnotations,
                    filesEditedThisTask: &filesEditedThisTask,
                    completionSummary: &completionSummary
                )
                if parseResult.taskCompleted { return }
                // Completion gates refused this task_complete — hand the refusal back
                // as its tool_result so the model fixes the gap and tries again.
                if let blocked = parseResult.blockedCompletion {
                    toolResults.append([
                        "type": "tool_result",
                        "tool_use_id": blocked.toolId,
                        "content": blocked.message
                    ])
                }
                let hasToolUse = parseResult.hasToolUse
                let pendingTools = parseResult.pendingTools

                // stop_reason-driven loop control: malformed tool calls, max_tokens
                // truncation, and premature end_turn get one corrective bounce
                // instead of silently completing. (The old phrase-match heuristic
                // appended its correction to toolResults, which finalize ignored
                // for text-only turns — the task completed anyway.)
                let routeText = (response.content.compactMap { $0["text"] as? String }).joined()
                // Tier 10.1: first truncation → re-send the SAME request with a
                // larger output budget (bounded by the context window; a 4K
                // window gets no escalation) before spending a continuation.
                if response.stopReason == "max_tokens", !hasToolUse, !maxTokensEscalated {
                    maxTokensEscalated = true
                    let effective = mt > 0 ? mt : (services.claude != nil ? 16_384 : 8_192)
                    if let bigger = Self.escalatedMaxTokens(
                        current: effective,
                        contextWindow: contextWindow(for: provider),
                        lastInputTokens: response.inputTokens)
                    {
                        mt = bigger
                        services = buildLLMServiceBundle(
                            provider: provider, modelName: modelName, isVision: isVision,
                            historyContext: historyContext, maxTokens: mt)
                        compactionState.maxTokens = mt
                        compactionState.refreshThreshold(contextWindow: contextWindow(for: provider))
                        appendLog("⚠️ Response truncated at max_tokens — retrying the same request with max_tokens \(effective) → \(bigger)")
                        flushLog()
                        rawLLMOutput = ""
                        streamPrefetch.drain().values.forEach { $0.cancel() }
                        continue taskLoop
                    }
                }
                let route = Self.routeStopReason(
                    stopReason: response.stopReason,
                    hasToolUse: hasToolUse,
                    hasPendingTools: !pendingTools.isEmpty,
                    responseText: routeText,
                    openCriteria: GoalStateStore.shared.current?.openCriteria.map(\.text) ?? [],
                    retriesUsed: stopRouteRetries,
                    maxTokensRetriesUsed: maxTokensRetries
                )
                if case .retry(let correction, let logLine) = route {
                    streamPrefetch.drain().values.forEach { $0.cancel() }
                    if response.stopReason == "max_tokens" { maxTokensRetries += 1 } else { stopRouteRetries += 1 }
                    appendLog(logLine)
                    flushLog()
                    // Keep text + thinking blocks — appending unparsable tool_use
                    // blocks without matching tool_results would 400 at the API,
                    // and thinking blocks must pass back unmodified.
                    let keepTypes: Set<String> = ["text", "thinking", "redacted_thinking"]
                    let textBlocks = response.content.filter { keepTypes.contains($0["type"] as? String ?? "") }
                    let assistantMsg: [String: Any] = [
                        "role": "assistant",
                        "content": textBlocks.isEmpty ? "(empty response)" : textBlocks
                    ]
                    messages.append(assistantMsg)
                    messages.append(["role": "user", "content": correction])
                    continue taskLoop
                }

                // Execute pending tools — partition into read/write batches
                // Consecutive read-only tools run in parallel; write tools serialize
                await executePendingToolBatches(
                    pendingTools: pendingTools,
                    toolResults: &toolResults,
                    prefetched: streamPrefetch.drain()
                )

                // Vision verification: auto-screenshot after UI actions so the LLM can see the result.
                await runVisionAutoScreenshotIfNeeded(
                    pendingTools: pendingTools,
                    isVision: isVision,
                    toolResults: &toolResults
                )

                // Tier 8.3: files the model read this task that changed on disk
                // behind its back (user, formatter, build, other tab) — surface
                // the diff now so the next edit isn't built on stale lines.
                if !toolResults.isEmpty {
                    let changed = Self.externalChangeBlocks(tabID: Self.mainTabID)
                    for block in changed {
                        toolResults.append(["type": "text", "text": block])
                    }
                    if !changed.isEmpty {
                        appendLog("📝 \(changed.count) read file(s) changed on disk — diff attached")
                        flushLog()
                    }
                }

                // Tier 10.4: a model that keeps calling tools never sees the
                // end_turn goal nudge — re-list the open criteria every 10
                // turns unless it touched goal_state (or was reminded) since.
                if pendingTools.contains(where: { $0.name == "goal_state" }) {
                    lastGoalActivity = iterations
                }
                if !toolResults.isEmpty, let reminder = Self.goalReminderBlock(
                    openCriteria: GoalStateStore.shared.current?.openCriteria.map(\.text) ?? [],
                    iteration: iterations,
                    lastGoalActivity: lastGoalActivity)
                {
                    lastGoalActivity = iterations
                    toolResults.append(["type": "text", "text": reminder])
                    appendLog("🎯 Goal reminder attached (iteration \(iterations))")
                    flushLog()
                }

                // Tier 10.5: on a ≥1M window, once past 25% usage, remind the
                // model once that the cached prefix is large — no re-reads,
                // narrow outputs, wrap up.
                if !toolResults.isEmpty, let note = Self.cacheWarmthReminderBlock(
                    contextWindow: contextWindow(for: provider),
                    inputTokens: response.inputTokens,
                    alreadySent: cacheWarmthSent)
                {
                    cacheWarmthSent = true
                    toolResults.append(["type": "text", "text": note])
                    appendLog("📦 Context past 25% of the 1M window — cache-warmth note attached")
                    flushLog()
                }

                // Token budget checks — nudge LLM or auto-stop if budget exhausted / diminishing returns
                if budgetTracker.shouldStop {
                    let reason = budgetTracker.isDiminishing ? "diminishing returns detected" : "token budget exhausted"
                    appendLog("⚠️ Auto-stopping: \(reason) (\(budgetTracker.statusDescription))")
                    flushLog()
                    break
                }
                if budgetTracker.shouldNudge && !toolResults.isEmpty {
                    // NOTE: must be a `text` block, not a synthetic `tool_result`.
                    // Anthropic rejects `tool_result` blocks whose `tool_use_id` has no
                    // matching `tool_use` in the prior assistant message.
                    toolResults.append([
                        "type": "text",
                        "text": """
                            ⚠️ Approaching token budget limit \
                            (\(budgetTracker.statusDescription)). \
                            Wrap up your current work and call \
                            task_complete with a summary.
                            """
                    ])
                }

                // Cost alerting — stop if estimated cost exceeds user-configured max
                if TokenUsageStore.shared.isCostExceeded {
                    let cost = String(format: "$%.2f", TokenUsageStore.shared.sessionEstimatedCost)
                    let max = String(format: "$%.2f", TokenUsageStore.shared.maxTaskCost)
                    appendLog("⚠️ Auto-stopping: estimated cost \(cost) exceeds limit \(max)")
                    flushLog()
                    break
                }

                // Overnight coding guards — read/build/error-budget/stuck-file nudges.
                let guardShouldBreak = runOvernightCodingGuards(
                    pendingTools: pendingTools,
                    toolResults: &toolResults,
                    unbuiltEditCount: &unbuiltEditCount,
                    consecutiveBuildFailures: &consecutiveBuildFailures,
                    stuckFiles: &stuckFiles,
                    isXcode: isXcode
                )
                if guardShouldBreak { break }

                // Collect completed sub-agent notifications and inject into tool results
                let subAgentNotifs = collectSubAgentNotifications()
                for notif in subAgentNotifs {
                    // Anthropic rejects `tool_result` blocks whose `tool_use_id` has no
                    // matching `tool_use` in the prior assistant message — use `text` instead.
                    toolResults.append(["type": "text", "text": notif])
                }

                let finalizeShouldBreak = finalizeTurnAndDetectCompletion(
                    responseContent: response.content,
                    hasToolUse: hasToolUse,
                    toolResults: toolResults,
                    messages: &messages,
                    textOnlyNudges: &textOnlyNudges

                )
                if finalizeShouldBreak { break taskLoop }

            } catch {
                let activeService: ActiveLLMService
                if services.claude != nil {
                    activeService = .claude
                } else if services.codex != nil {
                    activeService = .codex
                } else if services.openAICompatible != nil {
                    activeService = .openAICompatible
                } else if services.ollama != nil {
                    activeService = .ollama
                } else if services.foundationModel != nil {
                    activeService = .foundationModel
                } else {
                    activeService = .none
                }
                let outcome = await handleTaskLoopError(
                    error,
                    activeService: activeService,
                    providerDisplayName: provider.displayName,
                    messages: &messages,
                    timeoutRetryCount: &timeoutRetryCount,
                    maxTimeoutRetries: maxTimeoutRetries,
                    overflowCompactor: { [services] msgs in
                        // 413 / context overflow → same compactor as the
                        // threshold path, threshold check bypassed (Tier 7.7).
                        let overflowLog: (String) -> Void = { [weak self] m in
                            self?.appendLog(m); self?.flushLog()
                        }
                        return await Self.tieredCompact(
                            &msgs,
                            state: &compactionState,
                            summarizer: self.makeCompactSummarizer(services: services, log: overflowLog),
                            force: true,
                            log: overflowLog
                        )
                    }
                )
                switch outcome {
                case .continueLoop:
                    continue taskLoop
                case .breakLoop:
                    break taskLoop
                case .lowerMaxTokens(let newMT):
                    // Tier 10.3: same transcript, smaller output budget.
                    mt = newMT
                    compactionState.maxTokens = mt
                    compactionState.refreshThreshold(contextWindow: contextWindow(for: provider))
                    services = buildLLMServiceBundle(
                        provider: provider, modelName: modelName, isVision: isVision,
                        historyContext: historyContext, maxTokens: mt)
                    continue taskLoop
                case .fallbackRequested(let newProvider, let newModel, let newIsVision):
                    provider = newProvider
                    modelName = newModel
                    isVision = newIsVision
                    // Falling back can shrink the context window drastically
                    // (Claude 1M → local 32K); keep the old threshold and the
                    // new provider rejects the transcript before compaction
                    // ever fires.
                    compactionState = CompactionState(contextWindow: contextWindow(for: newProvider), maxTokens: mt)
                    services = buildLLMServiceBundle(
                        provider: provider,
                        modelName: modelName,
                        isVision: isVision,
                        historyContext: historyContext,
                        maxTokens: mt
                    )
                    continue taskLoop
                }
            }
        }

        // Apple Intelligence: suggest next steps after completion — fire-and-forget.
        // Runs after the task is already done; no reason to hold the user on it.
        if mediator.isEnabled && mediator.showAnnotationsToUser && !completionSummary.isEmpty && !commandsRun.isEmpty {
            let context = "Task: \(prompt)\nResult: \(completionSummary)\nCommands: \(commandsRun.joined(separator: ", "))"
            let capturedHandle = agentReplyHandle
            Task { [weak self] in
                guard let self else { return }
                if let nextSteps = await mediator.suggestNextSteps(context: context) {
                    self.appendLog(nextSteps.formatted)
                    self.flushLog()
                    if capturedHandle != nil {
                        self.sendProgressUpdate(nextSteps.formatted)
                    }
                }
            }
        }

        // Always save history if task didn't call task_complete
        if completionSummary.isEmpty {
            let summary = Task.isCancelled ? "(cancelled)" : commandsRun.isEmpty ? "(no actions)" : "(incomplete)"
            history.add(
                TaskRecord(prompt: prompt, summary: summary, commandsRun: commandsRun),
                maxBeforeSummary: maxHistoryBeforeSummary,
                apiKey: apiKey,
                model: selectedModel
            )
        }

        // End the task in SwiftData chat history
        ChatHistoryStore.shared.endCurrentTask(summary: completionSummary.isEmpty ? nil : completionSummary, cancelled: Task.isCancelled)

        // Stop progress updates
        stopProgressUpdates()

        flushLog()
        persistLogNow()
        isRunning = false
        isThinking = false
        userServiceActive = false
        rootServiceActive = false
        userWasActive = false
        rootWasActive = false
    }
}
