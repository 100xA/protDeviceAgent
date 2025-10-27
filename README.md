## protDeviceAgent

Prototype agent-system with on-device SLM for bachelor thesis (Jan Biernacki, 2025).

### What this is

- **On-device agent**: Runs a small language model locally using MLX. No cloud inference required.
- **Actionable tools**: The agent can search, open URLs, share text, compose messages, and read approximate location, with confirmations for sensitive actions.
- **Simple, auditable architecture**: Compact runtime, explicit tool registry, lightweight planning, and transparent logs/metrics.

## Getting started

1. Clone the repository:
```bash
git clone https://github.com/100xA/protDeviceAgent.git
```
2. Open `protDeviceAgent.xcodeproj` in Xcode.
3. Select a real iOS device as the run target and build/run.

Notes:
- A real device is required for features like SMS/WhatsApp composer, location, and in-app browser.
- On first use, the app will ask to download the local model. Approve the prompt to warm up the model. Progress is visible in the UI and cached for future launches.
- iOS will prompt for permissions on-demand (e.g., Contacts for resolving names in the SMS composer; Location for coordinates).

## Features

- **Local LLM orchestration**: Download, warmup, and generate tokens fully on device via MLX.
- **Intent classification**: Quick heuristic routing of inputs to conversation, tool use, or hybrid.
- **Multi-step planning**: Lightweight rule-based planner with LLM backfill for unmatched clauses.
- **Tool execution**: Side-effecting actions with confirmations and parameter validation.
- **Transparency**: Memory of the interaction, step-by-step tool results, and metrics (TTFT, TPS, durations, thermal state, RSS).

## Architecture overview

- `AgentRuntime`: Central coordinator. Classifies input, warms the model, plans steps, validates parameters, prompts for confirmation, executes tools, records memory and metrics.
- `LLMInference`: Model lifecycle and inference (download/warmup/generate). Exposes `generateResponse`, tool selection and plan proposal helpers, and logs inference metrics.
- `AgentPlanner`: Creates minimal multi-step plans using heuristics, with LLM backfill for unmatched intents. Supports simple dependencies and artifact templating.
- `IntentRouter`: Heuristic classifier routing inputs to conversation, tool use, or hybrid flows.
- `ToolExecutor`: Implements concrete side effects on-device (search, open URL, share, SMS composer, WhatsApp, location, wait) and logs per-tool metrics.
- `ToolRegistry`: Declares available tools, parameters, and which require confirmation.
- `ToolValidation`: Validates parameters against declared schemas.
- `UIPresentationCoordinator` and `ConfirmationManager`: Safe UI presentation for Safari/share sheets and user approvals.
- `AgentMemory`: Captures user/assistant messages, tool calls, and results for UI display and debugging.

UI (SwiftUI):
- `Views/ChatInterface.swift`: Chat-like shell to interact with the agent.
- `Views/VoiceInterface.swift`: Voice capture UI (if used in your flow).
- `Views/LogsView.swift`: Structured logs/trace surface.
- `Views/SettingsView.swift`: Toggles (e.g., auto-approve), model status, and utilities.
- `Views/TokensPerSecondView.swift` and `Views/DownloadProgressView.swift`: Performance and download status.
- `Views/LocationMapView.swift`: Simple current location visualization.

## Capabilities and tools

All tools are declared in `Core/Services/ToolRegistry.swift` and validated by `ToolValidation.swift`. Sensitive tools require confirmation.

- **search_web**
  - Parameters: `query: string`
  - Opens a Google search in an in-app browser.
  - Confirmation: no

- **produce_text**
  - Parameters: `prompt: string`
  - Generates text locally via the LLM.
  - Confirmation: no

- **open_url**
  - Parameters: `urlString: url`
  - Opens a URL in an in-app Safari view.
  - Confirmation: no

- **get_location**
  - Parameters: none
  - Returns latitude/longitude with approximate accuracy (requests Location permission when needed).
  - Confirmation: no

- **send_whatsapp**
  - Parameters: `phone?: phone`, `message: string`
  - Opens WhatsApp if available; otherwise falls back to `wa.me` in a browser.
  - Confirmation: yes

- **send_message**
  - Parameters: `recipient?: string`, `message: string`
  - Opens the Messages composer; the user still sends the message manually.
  - Confirmation: yes

- **share_content**
  - Parameters: `text: string`
  - Presents the iOS share sheet (e.g., save to Notes).
  - Confirmation: yes

- **wait**
  - Parameters: `seconds: int`
  - Pauses flow briefly to space multi-action plans.
  - Confirmation: no

Planner notes:
- The planner splits inputs into simple clauses, maps known phrases to tools, and can request LLM backfill for unmatched intents (with a short timeout and step cap).
- Steps can depend on prior artifacts using templating like `${<stepId>.artifacts.text}`; resolution happens before validation/execution.

## Example prompts

- "search for swift concurrency best practices"
  - Opens an in-app Safari search.
- "open github.com/apple/swift"
  - Opens the URL.
- "where am I"
  - Returns coordinates with accuracy meters.
- "text to Alice: On my way!"
  - Opens Messages composer with resolved contact when possible.
- "write a short note about tomorrow’s meeting and save it to Notes"
  - Generates note text then opens the share sheet to save it.

## Metrics and experimentation

- Inference metrics: duration, time-to-first-token, tokens/sec are logged by `LLMInference`.
- E2E metrics per request: memory (RSS) deltas and thermal state are logged by `AgentRuntime`.
- Per-tool metrics: duration, pre/post RSS, thermal state, success flag are logged by `ToolExecutor`.
- UI surfaces: `TokensPerSecondView`, `LogsView`.
- Tests: `protDeviceAgentTests/ScenarioTests.swift` exercises the scenario runner and summarizes results.

## Development

Add a new tool:
1. Declare it in `ToolRegistry` with `ToolParameterSpec`s and `requiresConfirmation`.
2. Implement behavior in `ToolExecutor.execute(name:parameters:)`, returning a `ToolResult` with any artifacts.
3. Extend `ToolValidation` if you introduce a new parameter type.
4. (Optional) Teach `AgentPlanner` to recognize phrases mapping to the tool; otherwise the LLM backfill may propose it.
5. Consider UI presentation via `UIPresentationCoordinator` for any modals/sheets.

Change the model:
- See `Models/ModelRegistery+custom.swift`. The app currently uses `mlx-community/gemma-2-2b-it-4bit`. Update `LLMInference.modelConfiguration` to switch models.

## Privacy and safety

- Inference is local; prompts and generations remain on-device.
- Sensitive actions (SMS/WhatsApp/share) require an explicit user confirmation, and final sending happens through system UI.
- Contacts access is only used to resolve recipient names for SMS and is requested on-demand.
- Location is requested on-demand for `get_location` and not stored.

## Troubleshooting

- Model warmup not starting: Ensure you approved the download prompt and have network connectivity for the initial fetch. Progress appears in the UI; subsequent runs use the cached model.
- SMS composer not appearing: Some features require a real device and a configured Messages account. Simulators cannot send texts.
- WhatsApp not installed: The app falls back to opening `wa.me` in the browser.
- URL fails to open: Ensure the input includes a valid scheme (the app will prefix `https://` if missing) and that it’s a valid URL string.
- No tool matched: The agent will reply that no tool applies; try simpler phrasing like “search …”, “open …”, “text …”.

## Inspiration

This work was inspired by the MLX sample projects that demonstrate running language/vision models on-device with MLX Swift. It is based on the [MLXSampleApp](https://github.com/ibrahimcetin/MLXSampleApp).


