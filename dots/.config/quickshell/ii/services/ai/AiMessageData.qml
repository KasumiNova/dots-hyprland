import QtQuick;

/**
 * Represents a message in an AI conversation. (Kind of) follows the OpenAI API message structure.
 */
QtObject {
    property int backendId: -1  // ID in the backend database (-1 = not synced)
    property string role
    property string content
    property string rawContent
    property string fileMimeType
    property string fileUri
    property string localFilePath
    property string model
    property bool thinking: true
    property bool done: false
    property var annotations: []
    property var annotationSources: []
    property list<string> searchQueries: []
    property string functionName  // Legacy: first tool name for display
    property var functionCall  // Legacy: first tool call for compatibility
    property string functionResponse  // Legacy: first tool response
    property bool functionPending: false
    
    // New: support multiple parallel tool calls
    property var toolCalls: []  // Array of {id, name, args, status, result}

    // Token usage for the request that produced this message (OpenAI-style usage).
    // These are stored in backend for cumulative per-chat stats.
    property int usagePromptTokens: -1
    property int usageCompletionTokens: -1
    property int usageTotalTokens: -1
    property bool usageEstimated: false
    property bool visibleToUser: true
}
