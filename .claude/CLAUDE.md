# Agent - macOS Autonomous Agent with Privileged Daemon

## Agent! Identity
- **Official birthday: April 1st**. The first
  commit in this repo's squashed history is 2026-04-06, but April 1st is the official date.

## Project Overview
A macOS SwiftUI app that uses SMAppService + a privileged Launch Daemon to give an autonomous Claude-powered agent root-level command execution. The user approves the daemon once, then the agent can execute commands autonomously via XPC.

## Build & Run
- Open `Agent.xcodeproj` in Xcode
- Two targets: **Agent** (app) and **AgentHelper** (privileged daemon tool)
- Development Team: **469UCUB275**
- Deployment target: macOS 26.0, Swift 6.2
- Build with XCF: `xcf build` (ensure Agent.xcodeproj is selected, NOT CloneTool)
- After successful xcf build, do a git commit

## Architecture

### Targets
1. **Agent** (main app) - SwiftUI app with @Observable ViewModel pattern
2. **AgentHelper** (command-line tool) - Privileged daemon that executes commands as root

### Key Files
- `Agent/AgentApp.swift` - @main entry point
- `Agent/ContentView.swift` - Main UI (header, activity log, screenshot previews, input)
- `Agent/AgentViewModel.swift` - Orchestrator: task loop, screenshots, clipboard
- `Agent/ClaudeService.swift` - Anthropic Messages API wrapper
- `Agent/HelperService.swift` - XPC client + SMAppService registration
- `Agent/HelperProtocol.swift` - Shared XPC protocol definitions
- `Agent/Models.swift` - AgentError enum + TaskHistory persistence
- `AgentHelper/main.swift` - Privileged daemon with NSXPCListener
- `Agent/LaunchDaemons/Agent.app.toddbruss.helper.plist` - Daemon configuration

### XPC Communication
- Mach service: `Agent.app.toddbruss.helper`
- HelperToolProtocol: `execute(script:instanceID:withReply:)`, `cancelOperation(instanceID:withReply:)`
- HelperProgressProtocol: `progressUpdate(_:)` for streaming output
- Uses `.privileged` option for NSXPCConnection

### LLM Integration
- Multi-provider: Claude, Ollama, OpenAI-compatible, Apple Intelligence (Foundation Models)
- SSE streaming for Claude; native tool calling for all providers
- Consolidated CRUDL tools reduce tool count for small models:
  - `git` (actions: status, diff, log, commit, diff_patch, branch)
  - `xcode` (actions: build, run, list_projects, select_project, grant_permission)
  - `agent_script` (actions: list, read, create, update, run, delete, combine)
  - `applescript_tool` (actions: execute, lookup_sdef, list, run, save, delete)
  - `javascript_tool` (actions: execute, list, run, save, delete)
  - `accessibility` (actions: list_windows, get_properties, perform_action, click, type_text, etc.)
  - `web` / `selenium` (consolidated web automation)
  - `plan_mode` (actions: create, update, read, list, delete — multi-plan support)
- File tools remain individual: `read_file`, `write_file`, `edit_file`, `list_files`, `search_files`, `create_diff`, `apply_diff`
- `expandConsolidatedTool()` dispatcher maps consolidated names to legacy handlers
- System prompts stored at ~/Documents/AgentScript/system/ with version-based re-sync
- Prompt revision number in SystemPromptService forces re-sync on prompt changes

### Tool Groups
- **Core**: task_complete, list_tools, load_groups, unload_groups, web_search, conversation tools
- **Workflow**: git, agent_script, plan_mode, send_message
- **Coding**: read_file, write_file, edit_file, create_diff, apply_diff, list_files, search_files, xcode
- **Automation**: applescript_tool, accessibility, javascript_tool
- **Web**: web, selenium
- **User Agent / Launch Daemon**: execute_agent_command / execute_daemon_command
- Groups loaded per task mode; Workflow always included alongside Core

### Scripting Priority
1. **agent_script (action: run)** — native Swift dylibs with full TCC, 100% Swift (ScriptingBridge only for apps with SDEF)
2. **applescript_tool (action: execute)** — NSAppleScript in-process with TCC
3. **execute_agent_command (sh)** — shell scripts via UserService XPC, runs as user
- User agent handles most tasks; root daemon only for admin duties (disk cloning, software install, system config)
- Chown/chmod files back to user after root operations

### Important Patterns
- `@Observable` with stored properties + `didSet` for UserDefaults persistence (NOT computed properties)
- API key persisted in UserDefaults under "agentAPIKey"
- Model selection persisted under "agentModel"
- Activity log persists between tasks (only clears on trash button)
- TaskHistory persists to ~/Library/Application Support/Agent/task_history.json
- Screenshot capture via `/usr/sbin/screencapture -i`
- Clipboard paste: tries NSImage, raw PNG/TIFF/JPEG data, then file URLs
- Cmd+V intercepted via NSEvent.addLocalMonitorForEvents to detect image paste

## Known Issues & Lessons
- SMAppService `.notFound` status is unreliable; always try `register()` directly
- SourceKit may report false "Cannot find type in scope" errors - trust the Xcode build
- `onPasteOf` does not exist in SwiftUI; use NSEvent monitor + dedicated paste button
- TextField ignores image data on paste; cannot detect images via onChange
- SF Symbol "stamp" doesn't exist; use "photo.on.rectangle.angled" instead
