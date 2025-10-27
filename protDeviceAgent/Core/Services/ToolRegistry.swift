import Foundation

struct ToolRegistry {
    static let tools: [ToolDefinition] = [
        .init(
            name: "search_web",
            description: "Open a web search for a user query.",
            parameters: [.init(name: "query", type: "string", optional: false)],
            requiresConfirmation: false
        ),
        .init(
            name: "produce_text",
            description: "Use the local LLM to produce text from a prompt.",
            parameters: [
                .init(name: "prompt", type: "string", optional: false)
            ],
            requiresConfirmation: false
        ),
        .init(
            name: "open_url",
            description: "Open a URL in the system browser.",
            parameters: [.init(name: "urlString", type: "url", optional: false)],
            requiresConfirmation: false
        ),
        .init(
            name: "get_location",
            description: "Get current device coordinates (with accuracy).",
            parameters: [],
            requiresConfirmation: false
        ),
        .init(
            name: "send_whatsapp",
            description: "Open WhatsApp or wa.me with a prefilled message.",
            parameters: [
                .init(name: "phone", type: "phone", optional: true),
                .init(name: "message", type: "string", optional: false)
            ],
            requiresConfirmation: true
        ),
        .init(
            name: "send_message",
            description: "Open SMS composer with recipient and message.",
            parameters: [
                .init(name: "recipient", type: "string", optional: true),
                .init(name: "message", type: "string", optional: false)
            ],
            requiresConfirmation: true
        ),
        .init(
            name: "share_content",
            description: "Open the iOS share sheet with provided text.",
            parameters: [
                .init(name: "text", type: "string", optional: false)
            ],
            requiresConfirmation: true
        ),
        .init(
            name: "wait",
            description: "Pause execution for N seconds.",
            parameters: [
                .init(name: "seconds", type: "int", optional: false)
            ],
            requiresConfirmation: false
        )
    ]
}


