import AppKit
import Foundation

// MARK: - Logging, Streaming & Media

extension AgentViewModel {

    // MARK: - Error History

    /// Log an error to both the log and error history
    func appendError(_ error: Error, context: String = "") {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let errorMessage: String
        if let agentError = error as? AgentError {
            errorMessage = agentError.errorDescription ?? "Unknown error"
        } else {
            errorMessage = error.localizedDescription
        }

        let fullMessage = context.isEmpty ? errorMessage : "\(context): \(errorMessage)"
        let formattedMessage = "[\(timestamp)] ERROR: \(fullMessage)"

        // Store in SwiftData
        ChatHistoryStore.shared.appendMessage(formattedMessage)

        // Also store in error history
        let errorRecord = ErrorRecord(
            timestamp: Date(),
            message: fullMessage,
            errorType: String(describing: type(of: error)),
            context: context,
            stackTrace: Thread.callStackSymbols.joined(separator: "\n")
        )
        ErrorHistory.shared.add(errorRecord)

        // Also store per-tab error if a tab is active
        if let selectedId = selectedTabId,
           let tab = tab(for: selectedId)
        {
            tab.tabErrors.append("[\(timestamp)] \(String(describing: type(of: error))): \(fullMessage.truncate(to: 100))")
        }

        // Log to buffer
        if !logBuffer.isEmpty && !logBuffer.hasSuffix("\n") {
            logBuffer += "\n"
        }
        logBuffer += formattedMessage + "\n"
        scheduleLogFlush()
    }

    /// Log a tool error with specific tool context
    func appendToolError(tool: String, error: Error, input: [String: Any]? = nil) {
        var context = "Tool '\(tool)' failed"
        if let input = input, !input.isEmpty {
            let inputStr = input.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            context += " with input: \(inputStr)"
        }
        appendError(error, context: context)
    }

    /// Log a task error (when a whole task fails)
    func appendTaskError(task: String, error: Error, commandsRun: [String] = []) {
        var context = "Task '\(task.truncate(to: 50))' failed"
        if !commandsRun.isEmpty {
            context += ", commands run: \(commandsRun.prefix(3).joined(separator: "; "))"
        }
        appendError(error, context: context)
    }

    // MARK: - Hi-res attachment cache

    /// Persist the full-resolution bytes of a pasted/dropped/screenshot image
    /// to ~/Library/Caches/Agent/attachments/<uuid>.png. Returns the written
    /// path so callers can surface it to the LLM (ASCII-only, no TCC).
    /// Falls back to re-encoding from NSImage when `originalData` is nil.
    @discardableResult
    func saveHiResAttachment(data originalData: Data?, image: NSImage) -> String? {
        let dir = Self.attachmentsCacheDir
        let url = dir.appendingPathComponent("\(UUID().uuidString).png")
        // Prefer the raw bytes we already have — they're the pristine original.
        if let data = originalData {
            // If it's already PNG we can drop it straight to disk.
            if data.count >= 8, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
                do { try data.write(to: url); return url.path } catch { /* fall through */ }
            }
            // Not PNG (could be TIFF/JPEG) — re-encode as PNG without downscaling.
            if let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:])
            {
                do { try png.write(to: url); return url.path } catch { /* fall through */ }
            }
        }
        // Last resort: round-trip through NSImage.tiffRepresentation at native size.
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:])
        {
            do { try png.write(to: url); return url.path } catch { /* fall through */ }
        }
        return nil
    }

    // MARK: - Screenshot

    func captureScreenshot() {
        let tempPath = NSTemporaryDirectory() + "agent_screenshot_\(UUID().uuidString).png"

        Task {
            let status = await Self.offMain {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", tempPath]
                process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                var env = ProcessInfo.processInfo.environment
                env["HOME"] = NSHomeDirectory()
                let extraPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "")
                process.environment = env
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus
                } catch {
                    return Int32(-1)
                }
            }

            guard status == 0,
                  FileManager.default.fileExists(atPath: tempPath),
                  let image = NSImage(contentsOfFile: tempPath),
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else
            {
                if status != 0 && status != -1 {
                    appendLog("❌ Screenshot failed (exit \(status))")
                }
                return
            }

            // Ask the user which resolution to send — same picker as paste.
            let scale = Self.promptForImageScale(defaultScale: pasteImageScale)
            pasteImageScale = scale
            let encoded = await Self.encodeImageToBase64(pngData, userScale: scale)
            let base64 = encoded?.base64 ?? pngData.base64EncodedString()
            let payloadData = encoded?.pngData ?? pngData

            if let tab = selectedTabId.flatMap({ tab(for: $0) }) {
                tab.attachedImages.append(image)
                tab.attachedImagesBase64.append(base64)
            } else {
                attachedImages.append(image)
                attachedImagesBase64.append(base64)
            }
            if let path = saveHiResAttachment(data: payloadData, image: image) {
                let w = encoded?.width ?? Int(image.size.width)
                let h = encoded?.height ?? Int(image.size.height)
                let pct = Int((scale * 100).rounded())
                appendLog("📎 Attached: \(path) (\(w)x\(h), sending at \(pct)%)")
            }
            try? FileManager.default.removeItem(atPath: tempPath)
        }
    }

    func removeAttachment(at index: Int) {
        guard attachedImages.indices.contains(index) else { return }
        attachedImages.remove(at: index)
        attachedImagesBase64.remove(at: index)
    }

    func removeAllAttachments() {
        attachedImages.removeAll()
        attachedImagesBase64.removeAll()
    }

    /// Try all pasteboard formats to grab an image.
    /// Returns true if image data was found (encoding happens async in background).
    @discardableResult
    func pasteImageFromClipboard() -> Bool {
        let pb = NSPasteboard.general

        var rawData: Data?

        // Try raw data types first (avoids full NSImage deserialization overhead)
        for type in [
            NSPasteboard.PasteboardType.png,
            NSPasteboard.PasteboardType.tiff,
            NSPasteboard.PasteboardType(rawValue: "public.jpeg")
        ]
        {
            if let data = pb.data(forType: type) {
                rawData = data
                break
            }
        }

        // Try NSImage as fallback
        if rawData == nil,
           let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           let img = images.first,
           let tiff = img.tiffRepresentation
        {
            rawData = tiff
        }

        // Try file URLs (e.g. screenshot file copied from Finder)
        if rawData == nil,
           let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL]
        {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "tiff", "bmp", "gif"].contains(ext),
                   let data = try? Data(contentsOf: url)
                {
                    rawData = data
                    break
                }
            }
        }

        guard let imageData = rawData else { return false }

        // Ask the user which resolution to send — blocks briefly but only on
        // paste, defaults to whatever they picked last time.
        let scale = Self.promptForImageScale(defaultScale: pasteImageScale)
        pasteImageScale = scale

        // Encode on a background thread to avoid blocking the main thread
        let currentTabId = selectedTabId
        Task {
            guard let encoded = await Self.encodeImageToBase64(imageData, userScale: scale) else { return }
            if let image = NSImage(data: imageData) {
                if let tabId = currentTabId, let tab = self.tab(for: tabId) {
                    tab.attachedImages.append(image)
                    tab.attachedImagesBase64.append(encoded.base64)
                } else {
                    attachedImages.append(image)
                    attachedImagesBase64.append(encoded.base64)
                }
                if let path = saveHiResAttachment(data: encoded.pngData, image: image) {
                    let pct = Int((scale * 100).rounded())
                    appendLog("📎 Attached: \(path) (\(encoded.width)x\(encoded.height), sending at \(pct)%)")
                }
            }
        }

        return true
    }

    /// Modal alert with four resolution choices. Returns 1.0 / 0.75 / 0.5 / 0.25.
    /// The button matching `defaultScale` is the default — Enter picks it.
    static func promptForImageScale(defaultScale: Double) -> Double {
        let choices: [(label: String, scale: Double)] = [
            ("Full", 1.0), ("¾", 0.75), ("½", 0.5), ("¼", 0.25)
        ]
        let alert = NSAlert()
        alert.messageText = "Attach image"
        alert.informativeText = "How much resolution to send to the model?"
        alert.alertStyle = .informational
        for choice in choices { alert.addButton(withTitle: choice.label) }
        // Make the last-used button the default (highlighted / Enter).
        let defaultIdx = choices.firstIndex { abs($0.scale - defaultScale) < 0.001 } ?? 2
        for (i, btn) in alert.buttons.enumerated() {
            btn.keyEquivalent = (i == defaultIdx) ? "\r" : ""
        }
        let response = alert.runModal()
        let idx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(idx) ? choices[idx].scale : defaultScale
    }

    /// Threshold above which a pasted string is captured as a chip attachment
    /// rather than inserted into the TextField (SwiftUI TextField stalls on
    /// very long content).
    static let pastedTextAttachmentThreshold = 2000

    /// If the clipboard holds a plain string longer than the threshold, attach
    /// it as a chip on the active tab (or the main viewModel) and return true
    /// so the Cmd+V handler swallows the event. Short strings fall through to
    /// default paste.
    @discardableResult
    func pasteLongTextAsAttachment() -> Bool {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), text.count >= Self.pastedTextAttachmentThreshold else {
            return false
        }
        let attachment = PastedText(text)
        if let tabId = selectedTabId, let tab = self.tab(for: tabId) {
            tab.pastedTexts.append(attachment)
        } else {
            pastedTexts.append(attachment)
        }
        return true
    }

    /// Encode image data to a base64 PNG string off the main thread.
    /// `userScale` multiplies the original dimensions (1.0=full, 0.75, 0.5, 0.25).
    /// Claude's per-image cap is 8000px per side, so we clamp to that when the
    /// user picks full and the source is huge.
    struct EncodedImage: Sendable {
        let base64: String
        let pngData: Data
        let width: Int
        let height: Int
    }

    private static nonisolated func encodeImageToBase64(_ data: Data, userScale: Double = 0.5) async -> EncodedImage? {
        // Read source dimensions without fully decoding the image.
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        let maxDim = 8000
        let targetW = Int((Double(w) * userScale).rounded())
        let targetH = Int((Double(h) * userScale).rounded())
        let scaleClamp = (targetW > maxDim || targetH > maxDim)
            ? min(Double(maxDim) / Double(targetW), Double(maxDim) / Double(targetH))
            : 1.0
        let newW = max(1, Int(Double(targetW) * scaleClamp))
        let newH = max(1, Int(Double(targetH) * scaleClamp))

        // No resize needed — decode at full size and re-encode as PNG.
        if newW == w && newH == h {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let pngData = pngEncode(cgImage)
            else { return nil }
            return EncodedImage(base64: pngData.base64EncodedString(), pngData: pngData, width: w, height: h)
        }

        // Image I/O thumbnail — Apple's optimized high-quality downscaler.
        // `kCGImageSourceThumbnailMaxPixelSize` takes the longer-edge target;
        // Image I/O preserves aspect ratio and applies its own pyramidal filter.
        let maxEdge = max(newW, newH)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
              let pngData = pngEncode(thumb)
        else { return nil }
        return EncodedImage(
            base64: pngData.base64EncodedString(),
            pngData: pngData,
            width: thumb.width,
            height: thumb.height
        )
    }

    private static nonisolated func pngEncode(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    // MARK: - Log Buffering

    /// Snapshot any image files found in text to persistent cache, rewriting paths to UUID copies.
    private func snapshotImages(in text: String) -> String {
        let nsText = text as NSString
        let matches = Self.imagePathRegex?.matches(in: text, range: NSRange(location: 0, length: nsText.length)) ?? []
        guard !matches.isEmpty else { return text }

        var result = text
        // Process in reverse so earlier offsets stay valid
        for match in matches.reversed() {
            let range = match.range(at: 1)
            let path = nsText.substring(with: range)

            // Skip if already a cached path (old or new cache dirs)
            if path.contains("/log_images/") || path.contains("/Caches/Agent/") { continue }

            // Skip if file doesn't exist
            guard FileManager.default.fileExists(atPath: path) else { continue }

            let ext = (path as NSString).pathExtension
            let uuid = UUID().uuidString
            let cachedURL = Self.logImageCacheDir.appendingPathComponent("\(uuid).\(ext)")

            do {
                try FileManager.default.copyItem(atPath: path, toPath: cachedURL.path)
                guard let swiftRange = Range(range, in: result) else { continue }
                result.replaceSubrange(swiftRange, with: cachedURL.path)
            } catch {
                // Copy failed — leave original path
            }
        }

        return result
    }

    nonisolated static let newTaskMarker = "--- New Task ---"

    /// Shared log formatting — prepends spacing for first task, strips blank lines before Cancelled.
    static func prepareLogBuffer(message: String, buffer: inout String, existingLog: String) {
        let combined = existingLog + buffer
        if message.contains(newTaskMarker) && !combined.contains(newTaskMarker) {
            buffer += String(repeating: "\n", count: 1)
        }
        if message.contains("Cancelled") {
            while buffer.hasSuffix("\n\n") { buffer.removeLast() }
        }
        if !buffer.isEmpty && !buffer.hasSuffix("\n") { buffer += "\n" }
    }

    func appendLog(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let cached = snapshotImages(in: message)
        // Multi-line messages (diffs, edit payloads, memory dumps) drop onto
        // their own line so the first content line isn't jammed next to the
        // timestamp — EXCEPT status summaries (✅/❌/⚠️/🛑) which should keep
        // the status prefix inline with the timestamp for scannability.
        let keepInlinePattern = #"^(✅|❌|⚠️|🛑|🚫|🍎|🧠|🧹|🔌|⏱|⏭|⏳|📝|📸|🔍|🔄|📎|📍|📊|📋|💭|🔒|🔓|👤|🤖|💬|📖|📁|📂)\s"#
        let keepInline = cached.range(of: keepInlinePattern, options: .regularExpression) != nil
        let formattedMessage = (cached.contains("\n") && !keepInline)
            ? "[\(timestamp)]\n\(cached)"
            : "[\(timestamp)] \(cached)"

        // Store in SwiftData
        ChatHistoryStore.shared.appendMessage(formattedMessage)

        Self.prepareLogBuffer(message: message, buffer: &logBuffer, existingLog: activityLog)
        logBuffer += formattedMessage + "\n"
        scheduleLogFlush()
    }

    func appendRawOutput(_ text: String) {
        guard !text.isEmpty else { return }
        let cached = snapshotImages(in: text)
        // Ensure first line starts on its own line so it doesn't run into a timestamp prefix
        var output = cached
        if !logBuffer.hasSuffix("\n") && !output.hasPrefix("\n") {
            output = "\n" + output
        }
        ChatHistoryStore.shared.appendMessage(output)
        logBuffer += output
        if !logBuffer.hasSuffix("\n") {
            logBuffer += "\n"
        }
        scheduleLogFlush()
    }

    /// Collapse heredoc bodies in commands to keep the log clean.
    /// "cat > file.html <<'EOF'\n<html>...\nEOF" -> "cat > file.html <<'EOF'\n...(heredoc)...\nEOF"
    static func collapseHeredocs(_ command: String) -> String {
        let lines = command.components(separatedBy: "\n")
        guard lines.count > 3 else { return command }

        // Find the line containing a heredoc marker: <<'DELIM', <<DELIM, <<"DELIM", <<-'DELIM'
        let pattern = #"<<-?\s*'?"?(\w+)'?"?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return command }

        for (i, line) in lines.enumerated() {
            let nsLine = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
                  match.range(at: 1).location != NSNotFound else { continue }
            let delimiter = nsLine.substring(with: match.range(at: 1))

            // Find the closing delimiter line after the heredoc start
            guard let endIdx = lines[(i + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == delimiter
            }), endIdx > i + 1 else { continue }

            // Collapse: keep lines before + heredoc line, placeholder, delimiter + remainder
            var result = Array(lines[...i])
            result.append("...(\(delimiter) heredoc)...")
            result.append(contentsOf: lines[endIdx...])
            return result.joined(separator: "\n")
        }
        return command
    }

    func resetStreamCounters() {
        streamLineCount = 0
        streamTruncated = false
    }

    func clearLog() {
        logBuffer = ""
        logFlushTask?.cancel()
        logFlushTask = nil
        logPersistTask?.cancel()
        logPersistTask = nil
        activityLog = ""
        lastTaskMessages = []
        ChatHistoryStore.shared.clearAll()
        // Clear Apple AI conversation context when log is cleared
        AppleIntelligenceMediator.shared.clearContext()
        // Clean up cached image snapshots
        try? FileManager.default.removeItem(at: Self.logImageCacheDir)
        try? FileManager.default.createDirectory(at: Self.logImageCacheDir, withIntermediateDirectories: true)
    }

    /// Clear the selected tab's log, or main log if no tab selected.
    func clearSelectedLog() {
        if let selectedId = selectedTabId,
           let tab = tab(for: selectedId)
        {
            tab.activityLog = ""
            tab.logBuffer = ""
            tab.logFlushTask?.cancel()
            tab.logFlushTask = nil
            tab.streamLineCount = 0
            tab.rawLLMOutput = ""
            tab.lastElapsed = 0
            tab.tabInputTokens = 0
            tab.tabOutputTokens = 0
            tab.thinkingDismissed = true
            tab.thinkingExpanded = false
            tab.thinkingOutputExpanded = false
            persistScriptTabs()
        } else {
            rawLLMOutput = ""
            thinkingDismissed = true
            thinkingExpanded = false
            thinkingOutputExpanded = false
            taskInputTokens = 0
            taskOutputTokens = 0
            clearLog()
        }
    }

    /// Clear everything: log, LLM output, prompt history, task history, token counts.
    func clearAll() {
        // Clear log
        clearSelectedLog()
        // Clear LLM output
        rawLLMOutput = ""
        thinkingDismissed = true
        thinkingExpanded = false
        thinkingOutputExpanded = false
        // Clear prompt history
        promptHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: "agentPromptHistory")
        historyIndex = -1
        savedInput = ""
        // Clear task history
        history.clearAll()
        // Clear token counts
        taskInputTokens = 0
        taskOutputTokens = 0
        sessionInputTokens = 0
        sessionOutputTokens = 0
        // Clear selected tab if applicable
        if let selectedId = selectedTabId,
           let tab = tab(for: selectedId)
        {
            tab.rawLLMOutput = ""
            tab.llmMessages = []
            tab.promptHistory.removeAll()
            tab.tabTaskSummaries.removeAll()
            tab.tabErrors.removeAll()
            tab.tabInputTokens = 0
            tab.tabOutputTokens = 0
            tab.historyIndex = -1
            tab.savedInput = ""
        }
        appendLog("🧹 All cleared.")
        flushLog()
    }

    // MARK: - LLM Streaming

    func appendStreamDelta(_ delta: String) {
        // Deltas arrive via detached `Task { @MainActor }` hops, so a trailing
        // "⚙️ tool" delta from the final turn can land AFTER task_complete has
        // appended the ✅ summary and flushStreamBuffer cleared
        // streamingTextStarted — the reset below would then wipe the summary,
        // leaving only the tool name in the HUD. Ignore deltas once the task is over.
        guard isRunning else { return }
        if !streamingTextStarted {
            rawLLMOutput = ""
            displayedLLMOutput = ""
            dripDisplayIndex = 0
        }
        streamingTextStarted = true
        rawLLMOutput += delta
        startDripIfNeeded()
    }

    /// Drip characters from rawLLMOutput into displayedLLMOutput one at a time (terminal effect)
    func startDripIfNeeded() {
        guard dripTask == nil else { return }
        dripTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                // Scalar-based indexing + adaptive chunking — see ScriptTab.startDripIfNeeded for rationale.
                let scalars = self.rawLLMOutput.unicodeScalars
                let total = scalars.count
                if self.dripDisplayIndex < total {
                    // Drip off (HUD option): dump everything instantly.
                    if !ScriptTab.dripEnabled {
                        self.displayedLLMOutput = self.rawLLMOutput
                        self.dripDisplayIndex = total
                        await ScriptTab.dripIdleTick()
                        continue
                    }
                    let pending = total - self.dripDisplayIndex
                    let chunk = max(1, pending / 100)
                    let start = scalars.index(scalars.startIndex, offsetBy: self.dripDisplayIndex)
                    let end = scalars.index(start, offsetBy: chunk)
                    self.displayedLLMOutput.unicodeScalars.append(contentsOf: scalars[start..<end])
                    self.dripDisplayIndex += chunk
                    await ScriptTab.dripEmitTick()
                } else if !self.streamingTextStarted {
                    break // Stream ended and all chars dripped
                } else {
                    await ScriptTab.dripIdleTick()
                }
            }
            self.dripTask = nil
        }
    }

    /// Collapse runs of 3+ newlines to 2 (one blank line max) to prevent huge gaps from chatty models.
    static func collapseNewlines(_ text: String) -> String {
        var result = ""
        var newlineCount = 0
        for ch in text {
            if ch == "\n" {
                newlineCount += 1
                if newlineCount <= 2 { result.append(ch) }
            } else {
                newlineCount = 0
                result.append(ch)
            }
        }
        return result
    }

    private func scheduleStreamFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task {
            self.streamFlushTask = nil
            if !self.streamBuffer.isEmpty {
                let collapsed = Self.collapseNewlines(self.streamBuffer)
                ChatHistoryStore.shared.appendStreamingContent(collapsed)
                self.activityLog = ScriptTab.capActivityLog(self.activityLog + collapsed)
                self.streamBuffer = ""
            }
        }
    }

    func flushStreamBuffer() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        var didFlush = false
        if !streamBuffer.isEmpty {
            let collapsed = Self.collapseNewlines(streamBuffer)
            ChatHistoryStore.shared.appendStreamingContent(collapsed)
            activityLog = ScriptTab.capActivityLog(activityLog + collapsed)
            streamBuffer = ""
            didFlush = true
        }
        if streamingTextStarted {
            if didFlush {
                ChatHistoryStore.shared.appendStreamingContent("\n")
                activityLog = ScriptTab.capActivityLog(activityLog + "\n")
            }
            streamingTextStarted = false
            // Let drip task finish naturally — no instant dump
        }
    }

    private func scheduleLogFlush() {
        guard logFlushTask == nil else { return }
        logFlushTask = Task {
            await ScriptTab.logFlushDebounce()
            flushLog()
        }
    }

    func flushLog() {
        logFlushTask?.cancel()
        logFlushTask = nil
        // Drain stream buffer first so streamed text precedes the log entries
        var combined = ""
        if !streamBuffer.isEmpty {
            ChatHistoryStore.shared.appendStreamingContent(streamBuffer)
            combined += streamBuffer
            streamBuffer = ""
        }
        // Ensure streamed text ends with a newline before timestamped entries
        if streamingTextStarted {
            ChatHistoryStore.shared.appendStreamingContent("\n")
            combined += "\n"
            streamingTextStarted = false
        }
        if !logBuffer.isEmpty {
            // Ensure timestamps always start on a new line
            if !activityLog.isEmpty && !activityLog.hasSuffix("\n") && combined.isEmpty {
                combined += "\n"
            }
            ChatHistoryStore.shared.save()
            combined += logBuffer
            logBuffer = ""
            schedulePersist()
        }
        // Single mutation of activityLog instead of multiple
        if !combined.isEmpty {
            activityLog = ScriptTab.capActivityLog(activityLog + combined)
            NotificationCenter.default.post(name: .activityLogDidChange, object: nil)
        }
    }

    private func schedulePersist() {
        guard logPersistTask == nil else { return }
        logPersistTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            logPersistTask = nil
            ChatHistoryStore.shared.save()
        }
    }

    func persistLogNow() {
        logPersistTask?.cancel()
        logPersistTask = nil
        ChatHistoryStore.shared.save()
    }
}
