import Testing
import Foundation
@testable import Agent_

// MARK: - Ollama text-embedded tool-call parsers

@Suite("OllamaService parsers")
struct OllamaParserTests {

    // extractFirstJSON

    @Test("extractFirstJSON returns the first balanced object and ignores trailing garbage")
    func firstJSONBalanced() {
        let json = OllamaService.extractFirstJSON(from: #"{"a":1,"b":{"c":"x"}} }}} trailing"#)
        #expect(json?["a"] as? Int == 1)
        #expect((json?["b"] as? [String: Any])?["c"] as? String == "x")
    }

    @Test("extractFirstJSON ignores braces inside strings and escaped quotes")
    func firstJSONStringsAndEscapes() {
        let json = OllamaService.extractFirstJSON(from: #"{"path":"a}b","q":"say \"hi\" }"}"#)
        #expect(json?["path"] as? String == "a}b")
        #expect(json?["q"] as? String == "say \"hi\" }")
    }

    @Test("extractFirstJSON returns nil for unbalanced or non-object input")
    func firstJSONInvalid() {
        #expect(OllamaService.extractFirstJSON(from: #"{"a":1"#) == nil)
        #expect(OllamaService.extractFirstJSON(from: "no json here") == nil)
        #expect(OllamaService.extractFirstJSON(from: "[1,2,3]") == nil)
    }

    // extractFirstToolCall

    @Test("extractFirstToolCall picks the earliest known tool name and parses its args")
    func firstToolCallEarliest() {
        // Tool names come from AgentTools.toolNames (consolidated names: file, git, xcode, ...)
        let text = #"I will run xcode {"action":"build"} and then git {"action":"status"}"#
        let call = OllamaService.extractFirstToolCall(from: text)
        #expect(call?.0 == "xcode")
        #expect(call?.2["action"] as? String == "build")
    }

    @Test("extractFirstToolCall tolerates up to 20 junk chars before the brace")
    func firstToolCallJunkTolerance() {
        let ok = OllamaService.extractFirstToolCall(from: #"xcode: args = {"action":"build"}"#)
        #expect(ok?.0 == "xcode")
        let junk = String(repeating: "-", count: 30)
        let tooFar = OllamaService.extractFirstToolCall(from: "xcode" + junk + #"{"action":"build"}"#)
        #expect(tooFar == nil)
    }

    @Test("extractFirstToolCall returns nil when no tool name is present")
    func firstToolCallNone() {
        #expect(OllamaService.extractFirstToolCall(from: "Just prose, no tools.") == nil)
    }

    // extractDeepSeekToolCalls

    @Test("DeepSeek V3.1 fullwidth-token format with tool_sep")
    func deepSeekV31() {
        let text = "<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>read_file<｜tool▁sep｜>{\"file_path\":\"/tmp/x\"}<｜tool▁call▁end｜><｜tool▁calls▁end｜>"
        let calls = OllamaService.extractDeepSeekToolCalls(from: text)
        #expect(calls?.count == 1)
        #expect(calls?.first?.name == "read_file")
        #expect(calls?.first?.input["file_path"] as? String == "/tmp/x")
    }

    @Test("DeepSeek legacy {name,parameters} format, ASCII pipes, multiple calls")
    func deepSeekLegacyMultiple() {
        let text = """
        <|tool_calls_begin|>
        <|tool_call_begin|>{"name":"list_files","parameters":{"path":"/a"}}<|tool_call_end|>
        <|tool_call_begin|>{"name":"read_file","arguments":{"file_path":"/b"}}<|tool_call_end|>
        <|tool_calls_end|>
        """
        let calls = OllamaService.extractDeepSeekToolCalls(from: text)
        #expect(calls?.count == 2)
        #expect(calls?[0].name == "list_files")
        #expect(calls?[0].input["path"] as? String == "/a")
        #expect(calls?[1].name == "read_file")
        #expect(calls?[1].input["file_path"] as? String == "/b")
    }

    @Test("DeepSeek parser returns nil without markers")
    func deepSeekNoMarkers() {
        #expect(OllamaService.extractDeepSeekToolCalls(from: "plain text") == nil)
    }

    // extractDSMLToolCalls

    @Test("DSML invoke/parameter blocks with string and non-string params")
    func dsmlParams() {
        let text = """
        <function_calls><invoke name="edit_file">
        <parameter name="file_path" string="true">/tmp/f.swift</parameter>
        <parameter name="count" string="false">3</parameter>
        <parameter name="flags" string="false">{"a":true}</parameter>
        </invoke></function_calls>
        """
        let calls = OllamaService.extractDSMLToolCalls(from: text)
        #expect(calls?.count == 1)
        #expect(calls?.first?.name == "edit_file")
        #expect(calls?.first?.input["file_path"] as? String == "/tmp/f.swift")
        #expect(calls?.first?.input["count"] as? Int == 3)
        #expect((calls?.first?.input["flags"] as? [String: Any])?["a"] as? Bool == true)
    }

    @Test("DSML tokens are stripped and a bare JSON body is accepted")
    func dsmlTokensStrippedJSONBody() {
        let text = "<｜DSML｜function_calls><｜DSML｜invoke name=\"read_file\">{\"file_path\":\"/x\"}</｜DSML｜invoke></｜DSML｜function_calls>"
        let calls = OllamaService.extractDSMLToolCalls(from: text)
        #expect(calls?.first?.name == "read_file")
        #expect(calls?.first?.input["file_path"] as? String == "/x")
    }

    @Test("DSML parser returns nil without invoke tags")
    func dsmlNone() {
        #expect(OllamaService.extractDSMLToolCalls(from: "nothing") == nil)
    }
}

// MARK: - Codex JWT claims

@Suite("CodexJWT")
struct CodexJWTTests {

    private func makeJWT(_ claims: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).sig"
    }

    @Test("claims decodes base64url payload")
    func claims() {
        let jwt = makeJWT(["sub": "user-1", "exp": 1_700_000_000.0])
        let c = CodexJWT.claims(jwt)
        #expect(c?["sub"] as? String == "user-1")
    }

    @Test("accountId reads nested chatgpt_account_id")
    func accountId() {
        let jwt = makeJWT(["https://api.openai.com/auth": ["chatgpt_account_id": "acct_123"]])
        #expect(CodexJWT.accountId(jwt) == "acct_123")
        #expect(CodexJWT.accountId(makeJWT(["sub": "x"])) == nil)
    }

    @Test("expiry converts exp seconds to Date")
    func expiry() {
        let jwt = makeJWT(["exp": 1_700_000_000.0])
        #expect(CodexJWT.expiry(jwt)?.timeIntervalSince1970 == 1_700_000_000)
        #expect(CodexJWT.expiry(makeJWT(["sub": "x"])) == nil)
    }

    @Test("malformed tokens return nil")
    func malformed() {
        #expect(CodexJWT.claims("not.a.jwt.at.all") == nil)
        #expect(CodexJWT.claims("onlyone") == nil)
        #expect(CodexJWT.claims("a.!!!.c") == nil)
    }
}

// MARK: - Codex freeform patch applier

@Suite("CodexPatchApplier")
struct CodexPatchApplierTests {

    private func makeTempDir() throws -> String {
        let path = NSTemporaryDirectory() + "codexpatch-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("Add File writes + prefixed body and creates intermediate dirs")
    func addFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let patch = """
        *** Begin Patch
        *** Add File: sub/new.txt
        +line one
        +line two
        *** End Patch
        """
        let r = CodexPatchApplier.apply(patch: patch, baseFolder: dir)
        #expect(r.files == ["sub/new.txt"])
        #expect(try String(contentsOfFile: dir + "/sub/new.txt", encoding: .utf8) == "line one\nline two")
        #expect(r.summary.contains("+ sub/new.txt"))
    }

    @Test("Update File applies context / remove / insert hunk")
    func updateFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "a\nb\nc\nd".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
        let patch = """
        *** Begin Patch
        *** Update File: f.txt
        @@
         a
        -b
        +B
        +B2
         c
        *** End Patch
        """
        let r = CodexPatchApplier.apply(patch: patch, baseFolder: dir)
        #expect(r.files == ["f.txt"])
        #expect(try String(contentsOfFile: dir + "/f.txt", encoding: .utf8) == "a\nB\nB2\nc\nd")
    }

    @Test("Update File reports context mismatch and leaves file untouched")
    func updateMismatch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "a\nb".write(toFile: dir + "/f.txt", atomically: true, encoding: .utf8)
        let patch = """
        *** Begin Patch
        *** Update File: f.txt
        -zzz
        +y
        *** End Patch
        """
        let r = CodexPatchApplier.apply(patch: patch, baseFolder: dir)
        #expect(r.files.isEmpty)
        #expect(r.summary.contains("context mismatch"))
        #expect(try String(contentsOfFile: dir + "/f.txt", encoding: .utf8) == "a\nb")
    }

    @Test("Delete File and Move File")
    func deleteAndMove() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try "x".write(toFile: dir + "/del.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: dir + "/old.txt", atomically: true, encoding: .utf8)
        let patch = """
        *** Begin Patch
        *** Delete File: del.txt
        *** Move File: old.txt
        *** To: new.txt
        *** End Patch
        """
        let r = CodexPatchApplier.apply(patch: patch, baseFolder: dir)
        #expect(Set(r.files) == ["del.txt", "old.txt", "new.txt"])
        #expect(!FileManager.default.fileExists(atPath: dir + "/del.txt"))
        #expect(!FileManager.default.fileExists(atPath: dir + "/old.txt"))
        #expect(try String(contentsOfFile: dir + "/new.txt", encoding: .utf8) == "y")
    }

    @Test("Preamble before Begin Patch is skipped; empty patch yields no-change summary")
    func preambleAndEmpty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let r = CodexPatchApplier.apply(patch: "chatter\n*** Begin Patch\n*** End Patch", baseFolder: dir)
        #expect(r.files.isEmpty)
        #expect(r.summary == "Patch applied (no changes detected).")
    }
}

// MARK: - OpenAI-compatible tool-call helpers

@Suite("OpenAIToolCallParsing")
struct OpenAIToolCallParsingTests {

    private func isAlnum9(_ s: String) -> Bool {
        s.count == 9 && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }

    @Test("shortToolId is 9 alphanumeric chars and unique across calls")
    func shortToolId() {
        let a = OpenAIToolCallParsing.shortToolId()
        let b = OpenAIToolCallParsing.shortToolId()
        #expect(isAlnum9(a))
        #expect(isAlnum9(b))
        #expect(a != b)
    }

    @Test("sanitizeToolId strips non-alphanumerics and truncates to 9")
    func sanitizeLong() {
        #expect(OpenAIToolCallParsing.sanitizeToolId("call_abc123DEF456xyz") == "callabc12")
        #expect(OpenAIToolCallParsing.sanitizeToolId("toolu_01ABCDEFGHIJ") == "toolu01AB")
        let padded = OpenAIToolCallParsing.sanitizeToolId("exactly-9!") // 8 clean chars -> 1 random pad
        #expect(padded.hasPrefix("exactly9"))
        #expect(isAlnum9(padded))
        #expect(OpenAIToolCallParsing.sanitizeToolId("abcdefghi") == "abcdefghi")
    }

    @Test("sanitizeToolId pads short ids to 9 keeping the clean prefix")
    func sanitizeShort() {
        let out = OpenAIToolCallParsing.sanitizeToolId("ab-c")
        #expect(out.hasPrefix("abc"))
        #expect(isAlnum9(out))
        let empty = OpenAIToolCallParsing.sanitizeToolId("")
        #expect(isAlnum9(empty))
    }

    @Test("isToolCallJSON accepts {name, arguments} objects, with surrounding whitespace")
    func toolCallJSONAccepts() {
        #expect(OpenAIToolCallParsing.isToolCallJSON(#"{"name":"git","arguments":{"action":"status"}}"#))
        #expect(OpenAIToolCallParsing.isToolCallJSON("  \n{\"name\": \"file\", \"arguments\": \"{}\"}\n"))
        #expect(OpenAIToolCallParsing.isToolCallJSON(#"{"name":"x","arguments":null}"#))
    }

    @Test("isToolCallJSON rejects prose, partial JSON, wrong shape, non-string name")
    func toolCallJSONRejects() {
        #expect(!OpenAIToolCallParsing.isToolCallJSON("Here is the plan: name and arguments"))
        #expect(!OpenAIToolCallParsing.isToolCallJSON(#"{"name":"git","arguments":"#))
        #expect(!OpenAIToolCallParsing.isToolCallJSON(#"{"name":"git"}"#))
        #expect(!OpenAIToolCallParsing.isToolCallJSON(#"{"arguments":{}}"#))
        #expect(!OpenAIToolCallParsing.isToolCallJSON(#"{"name":42,"arguments":{}}"#))
        #expect(!OpenAIToolCallParsing.isToolCallJSON(#"[{"name":"git","arguments":{}}]"#))
    }
}
