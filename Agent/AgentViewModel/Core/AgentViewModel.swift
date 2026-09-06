@preconcurrency import Foundation
import AgentTools
import AgentColorSyntax
import AgentTerminalNeo
import AgentLLM
import AgentAccess
import AppKit
import SwiftUI
import SQLite3
import Speech
import AVFoundation
import FoundationModels

@MainActor @Observable
final class AgentViewModel {
    /// Stable UUID for the main tab — persisted across launches
    static let mainTabID: UUID = {
        let key = "agentMainTabUUID"
        if let str = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: str) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()

    var taskInput = ""
    /// Width of the task input field, updated by InputSectionView via GeometryReader
    var inputFieldWidth: CGFloat = 0

    /// Tool steps for the current task (main tab) — ToolStep type is declared in AgentViewModel+Types.swift
    var toolSteps: [ToolStep] = []

    /// Raw LLM `messages` array from the most recent main-tab task. Carried over
    /// into the next task so the model continues the conversation (same behavior
    /// as ScriptTab.llmMessages). Sanitized on reuse — see MessageSanitizer.
    @ObservationIgnored var lastTaskMessages: [[String: Any]] = []
    /// When `lastTaskMessages` was last written (task end). Drives the
    /// Tier 7.6 time-based microcompact on the next task start.
    @ObservationIgnored var lastTaskMessagesDate: Date?

    // Stored property drives live UI; ChatHistoryStore persists across launches via SwiftData
    var activityLog = ""
    var isRunning = false
    var isThinking = false

    // MARK: - Coding Preferences (opt-in features)

    /// Auto-verify: after successful build, launch app and run accessibility checks
    var autoVerifyEnabled: Bool = UserDefaults.standard.bool(forKey: "codingAutoVerify") {
        didSet { UserDefaults.standard.set(autoVerifyEnabled, forKey: "codingAutoVerify") }
    }
    /// Critic review: one-shot LLM review of the task's diff before task_complete is accepted
    var criticReviewEnabled: Bool = UserDefaults.standard.bool(forKey: "codingCriticReview") {
        didSet { UserDefaults.standard.set(criticReviewEnabled, forKey: "codingCriticReview") }
    }
    /// Per-task flag — the critic runs at most once per task so a stubborn
    /// review can't loop task_complete forever. Reset at task start.
    var criticReviewDone: Bool = false
    /// Per-task count of task_complete refusals by the completion gates. Once
    /// it reaches `maxCompletionGateRefusals` the gates step aside so an
    /// unsatisfiable criterion can't loop the task to the iteration cap.
    /// Reset at task start.
    var completionGateRefusals: Int = 0
    static let maxCompletionGateRefusals = 3
    /// Visual test assertions: allow LLM to define click/verify UI tests
    var visualTestsEnabled: Bool = UserDefaults.standard.bool(forKey: "codingVisualTests") {
        didSet { UserDefaults.standard.set(visualTestsEnabled, forKey: "codingVisualTests") }
    }
    /// Auto PR: create branch, commit, push, open PR after task complete
    var autoPREnabled: Bool = UserDefaults.standard.bool(forKey: "codingAutoPR") {
        didSet { UserDefaults.standard.set(autoPREnabled, forKey: "codingAutoPR") }
    }
    /// Auto-scaffold: allow LLM to create new Xcode projects from templates
    var autoScaffoldEnabled: Bool = UserDefaults.standard.bool(forKey: "codingAutoScaffold") {
        didSet { UserDefaults.standard.set(autoScaffoldEnabled, forKey: "codingAutoScaffold") }
    }
    /// Auto-screenshot after UI actions (off by default — expensive, verbose).
    var visionAutoScreenshotEnabled: Bool = UserDefaults.standard.bool(forKey: "visionAutoScreenshot") {
        didSet { UserDefaults.standard.set(visionAutoScreenshotEnabled, forKey: "visionAutoScreenshot") }
    }
    var thinkingDismissed: Bool = UserDefaults.standard.object(forKey: "thinkingDismissed") as? Bool ?? true {
        didSet { UserDefaults.standard.set(thinkingDismissed, forKey: "thinkingDismissed") }
    }
    var showThinkingIndicator: Bool = UserDefaults.standard.object(forKey: "showThinkingIndicator") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showThinkingIndicator, forKey: "showThinkingIndicator") }
    }
    var thinkingExpanded: Bool = UserDefaults.standard.object(forKey: "thinkingExpanded") as? Bool ?? false {
        didSet { UserDefaults.standard.set(thinkingExpanded, forKey: "thinkingExpanded") }
    }
    var thinkingOutputExpanded: Bool = UserDefaults.standard.object(forKey: "thinkingOutputExpanded") as? Bool ?? false {
        didSet { UserDefaults.standard.set(thinkingOutputExpanded, forKey: "thinkingOutputExpanded") }
    }
    /// Expanded state of the Steps (tool calls) disclosure inside the LLM / Output HUD.
    /// Persisted across launches and Cmd+B hide/show so newly arriving steps don't collapse the list.
    var toolStepsExpanded: Bool = UserDefaults.standard.object(forKey: "toolStepsExpanded") as? Bool ?? false {
        didSet { UserDefaults.standard.set(toolStepsExpanded, forKey: "toolStepsExpanded") }
    }
    /// User's drag-resized height for the Steps list inside the LLM Output HUD. Persisted across launches.
    var toolStepsHeight: Double = UserDefaults.standard.object(forKey: "toolStepsHeight") as? Double ?? 200 {
        didSet { UserDefaults.standard.set(toolStepsHeight, forKey: "toolStepsHeight") }
    }
    /// Auto-scroll the Steps list to the newest step while the mouse is not hovering over it.
    var toolStepsAutoScroll: Bool = UserDefaults.standard.object(forKey: "toolStepsAutoScroll") as? Bool ?? true {
        didSet { UserDefaults.standard.set(toolStepsAutoScroll, forKey: "toolStepsAutoScroll") }
    }
    /// User's drag-resized height for the LLM Output HUD on the main tab. Persisted across launches.
    var llmOutputHeight: Double = UserDefaults.standard.object(forKey: "llmOutputHeight") as? Double ?? 80 {
        didSet { UserDefaults.standard.set(llmOutputHeight, forKey: "llmOutputHeight") }
    }
    var isListening = false
    var mainTaskStartDate: Date?
    var _mainTaskElapsedFrozen: TimeInterval = 0
    var mainTaskElapsed: TimeInterval {
        get {
            if let start = mainTaskStartDate, isRunning {
                return Date().timeIntervalSince(start)
            }
            return _mainTaskElapsedFrozen
        }
        set { _mainTaskElapsedFrozen = newValue }
    }

    // Failed agent alert
    var showFailedAgentAlert = false
    var failedAgentName = ""
    var failedAgentId: UUID?

    // Token tracking
    var taskInputTokens: Int = 0
    var taskOutputTokens: Int = 0
    var sessionInputTokens: Int = 0
    var sessionOutputTokens: Int = 0

    /// Live budget usage fraction for UI display (updated by task loop)
    var budgetUsedFraction: Double = 0

    /// Active sub-agents spawned by the current task
    var subAgents: [SubAgent] = []

    /// AskUserQuestion — pending question for mid-task dialog. ContentView observes
    /// `pendingQuestion` via @Observable and presents an NSAlert when it becomes non-empty.
    /// The alert's button handler then calls `provideAnswer(_:)`, which resumes the
    /// continuation stored when ask_user started waiting. No polling, no NotificationCenter.
    var pendingQuestion: String = ""
    @ObservationIgnored
    private var pendingAnswerContinuation: CheckedContinuation<String, Never>?

    /// Wait for the user to answer `question`, or for `timeout` seconds to elapse.
    /// Sets `pendingQuestion` so the UI can present the dialog; resumes when
    /// `provideAnswer(_:)` is called or the timeout fires.
    func awaitUserAnswer(_ question: String, timeout: TimeInterval = 300) async -> String {
        pendingQuestion = question
        let answer = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            pendingAnswerContinuation = cont
            // Timeout fallback — only fires if provideAnswer wasn't called in time.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                if let pending = self.pendingAnswerContinuation {
                    self.pendingAnswerContinuation = nil
                    pending.resume(returning: "(no answer — timed out after \(Int(timeout / 60)) minutes)")
                }
            }
        }
        pendingQuestion = ""
        return answer
    }

    /// Called by the UI when the user submits or skips the ask_user dialog.
    func provideAnswer(_ answer: String) {
        guard let cont = pendingAnswerContinuation else { return }
        pendingAnswerContinuation = nil
        cont.resume(returning: answer)
    }
    var userServiceActive = false
    var rootServiceActive = false
    var userWasActive = false
    var rootWasActive = false
    var userPingOK = false
    var daemonPingOK = false
    var userEnabled: Bool = UserDefaults.standard.object(forKey: "agentUserEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(userEnabled, forKey: "agentUserEnabled")
            if !userEnabled {
                userService.shutdownAgent()
                userPingOK = false
                appendLog("⚙️ User Agent shut down. Re-enable: Connect → Register.")
            }
            syncServicesGroup()
        }
    }
    var rootEnabled: Bool = UserDefaults.standard.object(forKey: "agentRootEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(rootEnabled, forKey: "agentRootEnabled")
            if !rootEnabled {
                helperService.shutdownDaemon()
                daemonPingOK = false
                appendLog("⚙️ Launch Daemon shut down. Re-enable: Connect → Register.")
            }
            syncServicesGroup()
        }
    }

    var selectedProvider: APIProvider = {
        let rawValue = UserDefaults.standard.string(forKey: "agentProvider") ?? "ollama"
        let provider = APIProvider(rawValue: rawValue) ?? .ollama
        return APIProvider.selectableProviders.contains(provider) ? provider : .ollama
    }() {
        didSet {
            guard APIProvider.selectableProviders.contains(selectedProvider) else {
                selectedProvider = .ollama
                return
            }
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "agentProvider")
            fetchModelsForSelectedProviderIfNeeded()
            // Sync to the active tab's LLMConfig so each tab remembers its own provider
            syncProviderToActiveTab()
        }
    }

    // Claude settings - stored securely in Keychain
    var apiKey: String = KeychainService.shared.get(.claude) ?? "" {
        didSet { KeychainService.shared.set(.claude, apiKey) }
    }

    var selectedModel: String = UserDefaults.standard.string(forKey: "agentModel") ?? "claude-sonnet-4-20250514" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "agentModel") }
    }

    // Ollama settings - API key stored securely in Keychain
    var ollamaAPIKey: String = KeychainService.shared.get(.ollama) ?? "" {
        didSet { KeychainService.shared.set(.ollama, ollamaAPIKey) }
    }

    // Tavily web search API key (available for all providers)
    var tavilyAPIKey: String = KeychainService.shared.get(.tavily) ?? "" {
        didSet { KeychainService.shared.set(.tavily, tavilyAPIKey) }
    }

    // Exa web search API key (available for all providers)
    var exaAPIKey: String = KeychainService.shared.get(.exa) ?? "" {
        didSet { KeychainService.shared.set(.exa, exaAPIKey) }
    }

    let ollamaEndpoint = "https://ollama.com/api/chat"

    // OpenAI settings
    var openAIAPIKey: String = KeychainService.shared.get(.openAI) ?? "" {
        didSet { KeychainService.shared.set(.openAI, openAIAPIKey) }
    }

    var openAIModel: String = UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-4.1-nano" {
        didSet { UserDefaults.standard.set(openAIModel, forKey: "openAIModel") }
    }

    var openAIModels: [OpenAIModelInfo] = []
    var isFetchingOpenAIModels = false

    // Codex (ChatGPT OAuth via ~/.codex/auth.json). No API key field — auth is
    // read from the Codex CLI's auth file at request time.
    var codexModel: String = UserDefaults.standard.string(forKey: "codexModel") ?? "gpt-5" {
        didSet { UserDefaults.standard.set(codexModel, forKey: "codexModel") }
    }
    var codexModels: [OpenAIModelInfo] = []
    var isFetchingCodexModels = false
    /// Context window per Codex model id, populated by `fetchCodexModels`.
    /// Consulted by the Thinking HUD so it shows the correct token ceiling for
    /// whichever Codex model is currently selected.
    var codexContextWindows: [String: Int] = [:]

    // DeepSeek settings
    var deepSeekAPIKey: String = KeychainService.shared.get(.deepSeek) ?? "" {
        didSet { KeychainService.shared.set(.deepSeek, deepSeekAPIKey) }
    }

    var deepSeekModel: String = UserDefaults.standard.string(forKey: "deepSeekModel") ?? "deepseek-chat" {
        didSet { UserDefaults.standard.set(deepSeekModel, forKey: "deepSeekModel") }
    }

    var deepSeekModels: [OpenAIModelInfo] = []
    var isFetchingDeepSeekModels = false

    // Hugging Face settings
    var huggingFaceAPIKey: String = KeychainService.shared.get(.huggingFace) ?? "" {
        didSet { KeychainService.shared.set(.huggingFace, huggingFaceAPIKey) }
    }

    var huggingFaceModel: String = UserDefaults.standard.string(forKey: "huggingFaceModel") ?? "deepseek-ai/DeepSeek-V3-0324" {
        didSet { UserDefaults.standard.set(huggingFaceModel, forKey: "huggingFaceModel") }
    }

    var huggingFaceModels: [OpenAIModelInfo] = []
    var isFetchingHuggingFaceModels = false

    // vLLM settings
    var vLLMAPIKey: String = KeychainService.shared.get(.vLLM) ?? "" {
        didSet { KeychainService.shared.set(.vLLM, vLLMAPIKey) }
    }

    var vLLMEndpoint: String = UserDefaults.standard.string(forKey: "vLLMEndpoint") ?? "http://localhost:8000/v1/chat/completions" {
        didSet { UserDefaults.standard.set(vLLMEndpoint, forKey: "vLLMEndpoint") }
    }

    var vLLMModel: String = UserDefaults.standard.string(forKey: "vLLMModel") ?? "" {
        didSet { UserDefaults.standard.set(vLLMModel, forKey: "vLLMModel") }
    }

    var vLLMModels: [OpenAIModelInfo] = []
    var isFetchingVLLMModels = false

    // LM Studio settings
    var lmStudioProtocol: LMStudioProtocol = {
        let raw = UserDefaults.standard.string(forKey: "lmStudioProtocol") ?? "openAI"
        return LMStudioProtocol(rawValue: raw) ?? .openAI
    }() {
        didSet {
            UserDefaults.standard.set(lmStudioProtocol.rawValue, forKey: "lmStudioProtocol")
            lmStudioEndpoint = lmStudioProtocol.defaultEndpoint
        }
    }

    var lmStudioEndpoint: String = UserDefaults.standard.string(forKey: "lmStudioEndpoint") ?? "http://localhost:1234/v1/chat/completions" {
        didSet { UserDefaults.standard.set(lmStudioEndpoint, forKey: "lmStudioEndpoint") }
    }

    var lmStudioModel: String = UserDefaults.standard.string(forKey: "lmStudioModel") ?? "" {
        didSet { UserDefaults.standard.set(lmStudioModel, forKey: "lmStudioModel") }
    }

    var lmStudioAPIKey: String = KeychainService.shared.get(.lmStudio) ?? "" {
        didSet { KeychainService.shared.set(.lmStudio, lmStudioAPIKey) }
    }

    var lmStudioModels: [OpenAIModelInfo] = []
    /// Context window per LM Studio model id, populated by `fetchLMStudioModels`
    /// from LM Studio's REST API (`/api/v0/models` → loaded_context_length /
    /// max_context_length). Without this the compaction threshold assumed a
    /// hardcoded 32K window for every local model and compacted far too early.
    var lmStudioContextWindows: [String: Int] = [:]
    var isFetchingLMStudioModels = false

    /// Context window per Ollama model name (cloud + local), populated by
    /// `fetchOllamaModels` / `fetchLocalOllamaModels` from `/api/show`
    /// (Modelfile num_ctx preferred, else the architecture's context_length).
    /// Used only when the user hasn't set an explicit context size.
    var ollamaContextWindows: [String: Int] = [:]

    /// Context window per vLLM model id, populated by `fetchVLLMModels` from
    /// `/v1/models` → max_model_len.
    var vLLMContextWindows: [String: Int] = [:]

    // Z.ai (ZhipuAI GLM) settings
    var zAIAPIKey: String = KeychainService.shared.get(.zAI) ?? "" {
        didSet { KeychainService.shared.set(.zAI, zAIAPIKey) }
    }

    var zAIModel: String = UserDefaults.standard.string(forKey: "zAIModel") ?? "glm-4.7" {
        didSet { UserDefaults.standard.set(zAIModel, forKey: "zAIModel") }
    }

    var zAIModels: [OpenAIModelInfo] = []
    var isFetchingZAIModels = false

    // MARK: - BigModel (China)

    var bigModelAPIKey: String = KeychainService.shared.get(.bigModel) ?? "" {
        didSet { KeychainService.shared.set(.bigModel, bigModelAPIKey) }
    }

    var bigModelModel: String = UserDefaults.standard.string(forKey: "bigModelModel") ?? "glm-4.7" {
        didSet { UserDefaults.standard.set(bigModelModel, forKey: "bigModelModel") }
    }

    // MARK: - Qwen (Alibaba DashScope)

    var qwenAPIKey: String = KeychainService.shared.get(.qwen) ?? "" {
        didSet { KeychainService.shared.set(.qwen, qwenAPIKey) }
    }

    var qwenModel: String = UserDefaults.standard.string(forKey: "qwenModel") ?? "qwen-plus" {
        didSet { UserDefaults.standard.set(qwenModel, forKey: "qwenModel") }
    }

    var qwenModels: [OpenAIModelInfo] = []
    var isFetchingQwenModels = false

    // MARK: - MiniMax

    var miniMaxAPIKey: String = KeychainService.shared.get(.miniMax) ?? "" {
        didSet { KeychainService.shared.set(.miniMax, miniMaxAPIKey) }
    }

    var miniMaxModel: String = UserDefaults.standard.string(forKey: "miniMaxModel") ?? "MiniMax-M3" {
        didSet { UserDefaults.standard.set(miniMaxModel, forKey: "miniMaxModel") }
    }

    var miniMaxModels: [OpenAIModelInfo] = []
    var isFetchingMiniMaxModels = false

    // MARK: - OpenRouter

    var openRouterAPIKey: String = KeychainService.shared.get(.openRouter) ?? "" {
        didSet { KeychainService.shared.set(.openRouter, openRouterAPIKey) }
    }

    var openRouterModel: String = UserDefaults.standard.string(forKey: "openRouterModel") ?? "" {
        didSet { UserDefaults.standard.set(openRouterModel, forKey: "openRouterModel") }
    }

    var openRouterModels: [OpenAIModelInfo] = []
    var isFetchingOpenRouterModels = false

    var openRouterProtocol: OpenRouterProtocol = {
        let raw = UserDefaults.standard.string(forKey: "openRouterProtocol") ?? "openAI"
        return OpenRouterProtocol(rawValue: raw) ?? .openAI
    }() {
        didSet { UserDefaults.standard.set(openRouterProtocol.rawValue, forKey: "openRouterProtocol") }
    }

    // MARK: - Google Gemini

    var geminiAPIKey: String = KeychainService.shared.get(.gemini) ?? "" {
        didSet { KeychainService.shared.set(.gemini, geminiAPIKey) }
    }

    var geminiModel: String = UserDefaults.standard.string(forKey: "geminiModel") ?? "gemini-2.5-flash" {
        didSet { UserDefaults.standard.set(geminiModel, forKey: "geminiModel") }
    }

    var geminiModels: [OpenAIModelInfo] = []
    var isFetchingGeminiModels = false

    // MARK: - Grok (xAI)

    var grokAPIKey: String = KeychainService.shared.get(.grok) ?? "" {
        didSet { KeychainService.shared.set(.grok, grokAPIKey) }
    }

    var grokModel: String = UserDefaults.standard.string(forKey: "grokModel") ?? "grok-3-mini-fast" {
        didSet { UserDefaults.standard.set(grokModel, forKey: "grokModel") }
    }

    var grokModels: [OpenAIModelInfo] = []
    var isFetchingGrokModels = false

    // MARK: - Mistral

    var mistralAPIKey: String = KeychainService.shared.get(.mistral) ?? "" {
        didSet { KeychainService.shared.set(.mistral, mistralAPIKey) }
    }

    var mistralModel: String = UserDefaults.standard.string(forKey: "mistralModel") ?? "mistral-large-latest" {
        didSet { UserDefaults.standard.set(mistralModel, forKey: "mistralModel") }
    }

    var mistralModels: [OpenAIModelInfo] = []
    var isFetchingMistralModels = false

    // MARK: - Codestral (codestral.mistral.ai)

    var codestralAPIKey: String = KeychainService.shared.get(.codestral) ?? "" {
        didSet { KeychainService.shared.set(.codestral, codestralAPIKey) }
    }

    var codestralModel: String = UserDefaults.standard.string(forKey: "codestralModel") ?? "codestral-latest" {
        didSet { UserDefaults.standard.set(codestralModel, forKey: "codestralModel") }
    }

    var codestralModels: [OpenAIModelInfo] = []
    var isFetchingCodestralModels = false

    // MARK: - Mistral Vibe (api.mistral.ai with Vibe key, Devstral models)

    var vibeAPIKey: String = KeychainService.shared.get(.vibe) ?? "" {
        didSet { KeychainService.shared.set(.vibe, vibeAPIKey) }
    }

    var vibeModel: String = UserDefaults.standard.string(forKey: "vibeModel") ?? "devstral-latest" {
        didSet { UserDefaults.standard.set(vibeModel, forKey: "vibeModel") }
    }

    var vibeModels: [OpenAIModelInfo] = []
    var isFetchingVibeModels = false

    var maxHistoryBeforeSummary: Int = UserDefaults.standard.object(forKey: "agentMaxHistory") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(maxHistoryBeforeSummary, forKey: "agentMaxHistory") }
    }

    var visibleTaskCount: Int = UserDefaults.standard.object(forKey: "agentVisibleTasks") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(visibleTaskCount, forKey: "agentVisibleTasks") }
    }

    var maxIterations: Int = UserDefaults.standard.object(forKey: "agentMaxIterations") as? Int ?? 50 {
        didSet { UserDefaults.standard.set(maxIterations, forKey: "agentMaxIterations") }
    }

    var maxRetries: Int = UserDefaults.standard.object(forKey: "agentMaxRetries") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(maxRetries, forKey: "agentMaxRetries") }
    }
    var networkRetryDelay: Int = UserDefaults.standard.object(forKey: "agentNetworkRetryDelay") as? Int ?? 60 {
        didSet { UserDefaults.standard.set(networkRetryDelay, forKey: "agentNetworkRetryDelay") }
    }

    // MARK: - Temperature per provider
    var claudeTemperature: Double = UserDefaults.standard.object(forKey: "claudeTemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(claudeTemperature, forKey: "claudeTemperature") }
    }
    var ollamaTemperature: Double = UserDefaults.standard.object(forKey: "ollamaTemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(ollamaTemperature, forKey: "ollamaTemperature") }
    }
    var openAITemperature: Double = UserDefaults.standard.object(forKey: "openAITemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(openAITemperature, forKey: "openAITemperature") }
    }
    var deepSeekTemperature: Double = UserDefaults.standard.object(forKey: "deepSeekTemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(deepSeekTemperature, forKey: "deepSeekTemperature") }
    }
    var huggingFaceTemperature: Double = UserDefaults.standard.object(forKey: "huggingFaceTemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(huggingFaceTemperature, forKey: "huggingFaceTemperature") }
    }
    var localOllamaTemperature: Double = UserDefaults.standard.object(forKey: "localOllamaTemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(localOllamaTemperature, forKey: "localOllamaTemperature") }
    }
    /// Context window size for local Ollama. 0 = let model decide.
    var localOllamaContextSize: Int = UserDefaults.standard.object(forKey: "localOllamaContextSize") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(localOllamaContextSize, forKey: "localOllamaContextSize") }
    }
    var vLLMTemperature: Double = UserDefaults.standard.object(forKey: "vLLMTemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(vLLMTemperature, forKey: "vLLMTemperature") }
    }
    var lmStudioTemperature: Double = UserDefaults.standard.object(forKey: "lmStudioTemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(lmStudioTemperature, forKey: "lmStudioTemperature") }
    }
    var zAITemperature: Double = UserDefaults.standard.object(forKey: "zAITemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(zAITemperature, forKey: "zAITemperature") }
    }
    var geminiTemperature: Double = UserDefaults.standard.object(forKey: "geminiTemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(geminiTemperature, forKey: "geminiTemperature") }
    }
    var grokTemperature: Double = UserDefaults.standard.object(forKey: "grokTemperature") as? Double ?? 0.2 {
        didSet { UserDefaults.standard.set(grokTemperature, forKey: "grokTemperature") }
    }
    var miniMaxTemperature: Double = UserDefaults.standard.object(forKey: "miniMaxTemperature") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(miniMaxTemperature, forKey: "miniMaxTemperature") }
    }

    /// Max output tokens per provider. 0 = let provider decide (omit from request).
    /// Claude API requires max_tokens so 0 defaults to 16384 at the service level.
    var maxTokens: Int = UserDefaults.standard.object(forKey: "maxTokens") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(maxTokens, forKey: "maxTokens") }
    }

    /// Reasoning effort: "off" (default), "low", "medium", "high".
    /// Claude providers get an extended-thinking budget scaled from this;
    /// OpenAI-compatible providers get reasoning_effort passed through.
    var reasoningEffort: String = UserDefaults.standard.string(forKey: "agentReasoningEffort") ?? "off" {
        didSet { UserDefaults.standard.set(reasoningEffort, forKey: "agentReasoningEffort") }
    }

    /// Per-task token budget ceiling (input+output). 0 = unlimited (default).
    /// When set, the task loop will nudge the LLM at 90% and auto-stop at 100% or on diminishing returns.
    var tokenBudgetCeiling: Int = UserDefaults.standard.object(forKey: "tokenBudgetCeiling") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(tokenBudgetCeiling, forKey: "tokenBudgetCeiling") }
    }

    var ollamaModel: String = UserDefaults.standard.string(forKey: "ollamaModel") ?? "" {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: "ollamaModel")
            if !ollamaModel.isEmpty && oldValue != ollamaModel {
                let vision = selectedOllamaSupportsVision ? " (vision)" : ""
                appendLog("🔄\(ollamaModel)\(vision)")
                flushLog()
            }
        }
    }

    var availableClaudeModels: [ClaudeModelInfo] = []
    var isFetchingClaudeModels = false

    var ollamaModels: [OllamaModelInfo] = []
    var isFetchingModels = false

    // Local Ollama settings
    var localOllamaEndpoint: String = UserDefaults.standard.string(forKey: "localOllamaEndpoint") ?? "http://localhost:11434/api/chat" {
        didSet { UserDefaults.standard.set(localOllamaEndpoint, forKey: "localOllamaEndpoint") }
    }

    var localOllamaModel: String = UserDefaults.standard.string(forKey: "localOllamaModel") ?? "" {
        didSet {
            UserDefaults.standard.set(localOllamaModel, forKey: "localOllamaModel")
            if !localOllamaModel.isEmpty && oldValue != localOllamaModel {
                let vision = selectedLocalOllamaSupportsVision ? " (vision)" : ""
                appendLog("🔄\(localOllamaModel)\(vision)")
                flushLog()
            }
        }
    }

    var localOllamaModels: [OllamaModelInfo] = []
    var isFetchingLocalModels = false

    var projectFolder: String = UserDefaults.standard.string(forKey: "agentProjectFolder") ?? "" {
        didSet { UserDefaults.standard.set(projectFolder, forKey: "agentProjectFolder") }
    }

    var attachedImages: [NSImage] = []
    var attachedImagesBase64: [String] = []

    /// Last-used scale for the paste-image resolution popup. One of
    /// 1.0 (full), 0.75, 0.5, 0.25. Persists so the popup's default
    /// button matches whatever the user picked last time.
    var pasteImageScale: Double = UserDefaults.standard.object(forKey: "pasteImageScale") as? Double ?? 0.5 {
        didSet { UserDefaults.standard.set(pasteImageScale, forKey: "pasteImageScale") }
    }
    /// Snapshot of attachments at task-start time. The input-bar buffers are
    /// cleared before the LLM loop runs, but `copy_image(source:"chat")`
    /// still needs to reach the original images during the task. Tab tasks
    /// use `ScriptTab.taskScopeImages` for the same reason.
    var taskScopeImages: [NSImage] = []

    /// Long pasted text — captured as chips above the TextField instead of
    /// inlined into SwiftUI's TextField (which stalls on huge content).
    var pastedTexts: [PastedText] = []

    /// Force vision mode for all providers (for testing image sending)
    var forceVision: Bool = UserDefaults.standard.bool(forKey: "agentForceVision") {
        didSet { UserDefaults.standard.set(forceVision, forKey: "agentForceVision") }
    }

    var promptHistory: [String] = UserDefaults.standard.stringArray(forKey: "agentPromptHistory") ?? []
    var historyIndex = -1
    var savedInput = ""

    let helperService = HelperService()
    let userService = UserService()
    let scriptService = ScriptService()
    let history = TaskHistory.shared
    var isCancelled = false
    var runningTask: Task<Void, Never>?
    var mainTaskQueue: [String] = []
    var currentTaskPrompt: String = ""
    var currentAppleAIPrompt: String = ""
    /// Commands run during current task — used by history, mediator, and tool handlers.
    var commandsRun: [String] = []
    @ObservationIgnored private var terminationObserver: Any?

    // MARK: - Messages Monitor
    var messagesMonitorEnabled: Bool = UserDefaults.standard.object(forKey: "agentMessagesMonitor") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(messagesMonitorEnabled, forKey: "agentMessagesMonitor")
            if messagesMonitorEnabled {
                startMessagesMonitor()
            } else {
                stopMessagesMonitor()
            }
        }
    }
    var messagesMonitorTask: Task<Void, Never>?
    /// FSEventStream watcher on ~/Library/Messages/ — wakes pollMessages when chat.db-wal changes
    /// instead of running on a 5-second tick.
    @ObservationIgnored
    var messagesDBWatcher: ChatDBWatcher?
    /// ROWID of the last message we've already processed
    var lastSeenMessageROWID: Int = 0
    /// Briefly true during each poll cycle so the StatusDot pulses on the timer
    var messagesPolling = false
    /// Handle ID to reply to when an Agent! task completes (nil = no reply needed)
    var agentReplyHandle: String?
    /// Task for periodic progress updates during long-running tasks
    var progressUpdateTask: Task<Void, Never>?
    /// Counter for progress updates sent
    var progressUpdateCount: Int = 0
    /// Current task description for progress updates
    var currentTaskDescription: String = ""
    /// Timestamp when the current task started
    var taskStartTime: Date?

    var messageFilter: MessageFilter = {
        MessageFilter(rawValue: UserDefaults.standard.string(forKey: "agentMessageFilter") ?? "") ?? .fromOthers
    }() {
        didSet { UserDefaults.standard.set(messageFilter.rawValue, forKey: "agentMessageFilter") }
    }

    var messageRecipients: [MessageRecipient] = []
    /// Set of handle IDs (phone/email) the user has enabled for monitoring
    var enabledHandleIds: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: "agentEnabledHandleIds") ?? []
        return Set(saved)
    }() {
        didSet { UserDefaults.standard.set(Array(enabledHandleIds), forKey: "agentEnabledHandleIds") }
    }

    // MARK: - Script Tabs

    var scriptTabs: [ScriptTab] = [] {
        didSet { rebuildTabIndex() }
    }
    var selectedTabId: UUID? { // nil = Main tab
        didSet { restoreProviderFromActiveTab() }
    }

    /// Re-entrancy guard: true while restoreProviderFromActiveTab is mid-flight so the
    /// chained selectedProvider.didSet doesn't overwrite the tab's user-picked model.
    var isRestoringProviderFromTab: Bool = false

    /// O(1) tab lookup by UUID
    private var tabsByID: [UUID: ScriptTab] = [:]


    /// The currently selected ScriptTab, or nil for main — O(1)
    var selectedTab: ScriptTab? {
        guard let id = selectedTabId else { return nil }
        return tabsByID[id]
    }

    /// O(1) tab lookup
    func tab(for id: UUID) -> ScriptTab? { tabsByID[id] }

    private func rebuildTabIndex() {
        tabsByID = Dictionary(uniqueKeysWithValues: scriptTabs.map { ($0.id, $0) })
    }

    // MARK: - Logging State

    static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var logBuffer = ""
    var logFlushTask: Task<Void, Never>?
    var logPersistTask: Task<Void, Never>?
    var streamLineCount = 0
    var streamTruncated = false
    /// Output that executeViaUserAgent already streamed live into the log for the
    /// tool currently being dispatched. Handlers that log their return value check
    /// this so the same text isn't shown twice (streamed, then re-logged).
    var lastStreamedOutput = ""
    var maxOutputLines: Int = UserDefaults.standard.object(forKey: "agentMaxOutputLines") as? Int ?? 1000 {
        didSet { UserDefaults.standard.set(maxOutputLines, forKey: "agentMaxOutputLines") }
    }

    var readFilePreviewLines: Int = UserDefaults.standard.object(forKey: "agentReadFilePreviewLines") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(readFilePreviewLines, forKey: "agentReadFilePreviewLines") }
    }

    var scriptCaptureStderr: Bool = UserDefaults.standard.object(forKey: "agentScriptCaptureStderr") as? Bool ?? false {
        didSet { UserDefaults.standard.set(scriptCaptureStderr, forKey: "agentScriptCaptureStderr") }
    }

    var taskAutoComplete: Bool = UserDefaults.standard.object(forKey: "agentTaskAutoComplete") as? Bool ?? true {
        didSet { UserDefaults.standard.set(taskAutoComplete, forKey: "agentTaskAutoComplete") }
    }

    var deletionLimit: Int = UserDefaults.standard.object(forKey: "agentDeletionLimit") as? Int ?? 10 {
        didSet { UserDefaults.standard.set(deletionLimit, forKey: "agentDeletionLimit") }
    }

    var terminalSpeed: TerminalSpeed = TerminalSpeed(rawValue: UserDefaults.standard.integer(forKey: "terminalSpeed")) ?? .current {
        didSet { UserDefaults.standard.set(terminalSpeed.rawValue, forKey: "terminalSpeed") }
    }

    var scanLinesEnabled: Bool = UserDefaults.standard.object(forKey: "scanLinesEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(scanLinesEnabled, forKey: "scanLinesEnabled") }
    }

    /// When on, the Activity Log starts below the LLM Output HUD instead of behind it.
    var hudLogBelow: Bool = UserDefaults.standard.object(forKey: "hudLogBelow") as? Bool ?? false {
        didSet { UserDefaults.standard.set(hudLogBelow, forKey: "hudLogBelow") }
    }

    /// Terminal drip-typing effect for LLM Output. When off, text appears instantly.
    var dripEnabled: Bool = UserDefaults.standard.object(forKey: "dripEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(dripEnabled, forKey: "dripEnabled") }
    }

    // LLM streaming state
    var streamBuffer = ""
    @ObservationIgnored var rawLLMOutput: String = UserDefaults.standard.string(forKey: "mainRawLLMOutput") ?? "" {
        didSet { UserDefaults.standard.set(rawLLMOutput, forKey: "mainRawLLMOutput") }
    }
    /// Character-by-character dripped version of rawLLMOutput for terminal effect
    var displayedLLMOutput: String = UserDefaults.standard.string(forKey: "mainRawLLMOutput") ?? ""
    var dripDisplayIndex: Int = (UserDefaults.standard.string(forKey: "mainRawLLMOutput") ?? "").unicodeScalars.count
    var dripTask: Task<Void, Never>?
    var streamFlushTask: Task<Void, Never>?
    var streamingTextStarted = false
    var recentOutputHashes: Set<Int> = []

    // MARK: - Image snapshot cache

    static let logImageCacheDir: URL = {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Agent/log_images")
        }
        let dir = caches.appendingPathComponent("Agent/log_images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Hi-res originals for images the user pastes / drops / screenshots.
    /// Separate from log_images (which caches copies of paths the LLM mentions)
    /// so we can keep the pristine original around for the full task. ASCII-only
    /// UUID filenames dodge the U+202F narrow-no-break-space macOS screenshot
    /// gotcha and every TCC-protected folder (Desktop, Documents, Downloads).
    static let attachmentsCacheDir: URL = {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Agent/attachments")
        }
        let dir = caches.appendingPathComponent("Agent/attachments")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let imagePathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(/[^\s"'<>]+\.(?:jpg|jpeg|png|gif|tiff|bmp|webp|heic))"#,
        options: .caseInsensitive
    )

    // MARK: - Voice Input

    var speechAudioEngine: AVAudioEngine?
    var speechRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    var speechRecognitionTask: SFSpeechRecognitionTask?
    var preDictationText: String = ""
    /// Tracks which tab was selected when dictation started, so speech goes to the correct input field
    var preDictationTabId: UUID?

    // MARK: - Hotword ("Agent!") Listening
    /// When true, mic stays open waiting for "Agent!" wake word
    var isHotwordListening = false {
        didSet { UserDefaults.standard.set(isHotwordListening, forKey: "isHotwordListening") }
    }
    /// True while capturing a command after the wake word was detected
    var isHotwordCapturing = false
    /// Timer that fires after 5 seconds of silence to auto-submit
    var hotwordSilenceTimer: Timer?
    /// Transcription length at last change — used to detect silence
    var hotwordLastTranscriptionLength = 0

    // MARK: - Init

    /// Prevents duplicate startup work when @State evaluates AgentViewModel() multiple times
    private static var _started = false

    init() {
        guard !Self._started else { return }
        Self._started = true

        // Register all LLM providers with AgentLLM framework
        LLMProviderSetup.registerAllProviders()

        activityLog = ChatHistoryStore.shared.buildActivityLogText(maxTasks: 3)
        // Trim main tab log on relaunch
        activityLog = ScriptTab.capActivityLog(activityLog)
        CodeBlockTheme.updateAppearance()
        TerminalNeoTheme.updateAppearance()
        // Restore ~/Documents/AgentScript/ and bundled resources if missing (off main thread)
        Task.detached { [scriptService = self.scriptService] in
            scriptService.ensurePackage()
            scriptService.rebuildAllMetadata()
            // Refresh upstream-bundled scripts when Agent! has been upgraded since last sync.
            // User-authored scripts are never touched; modified bundled scripts are backed up to .Trash.
            await scriptService.syncBundledScriptsFromRemote()
            let names = Set(scriptService.listScripts().map { $0.name.lowercased() })
            await MainActor.run { AppleIntelligenceMediator.knownAgentNames = names }
        }
        SystemPromptService.shared.ensureDefaults()

        restoreScriptTabs()
        syncServicesGroup()

        // Register with Daemon and UserService
        registerDaemon()
        registerAgent()

        // Add observer for app termination
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.persistScriptTabs()
            }
        }

        // No auto-fetch on launch — avoids wasting API calls for inactive LLMs.
        // Xcode Command Line Tools check is handled by DependencyOverlay in ContentView.

        restoreMessagesMonitor()
        startupPingWarmup()
    }
}
