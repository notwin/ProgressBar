import Foundation

enum AgentSource: String, Codable, CaseIterable, Sendable { case claude, codex }
enum AgentItemKind: String, Codable, Sendable { case goal, planStep = "plan_step", todo }

enum AgentItemStatus: String, Codable, Sendable {
    case pending, inProgress = "in_progress", blocked, done

    init?(claudeStatus: String) {
        switch claudeStatus {
        case "pending": self = .pending
        case "in_progress": self = .inProgress
        case "completed": self = .done
        default: return nil
        }
    }

    init?(codexGoalStatus: String) {
        switch codexGoalStatus {
        case "active": self = .inProgress
        case "paused", "blocked", "usageLimited", "budgetLimited": self = .blocked
        case "complete": self = .done
        default: return nil
        }
    }

    var taskStatus: TaskStatus {
        switch self {
        case .pending: return .pending
        case .inProgress: return .inProgress
        case .blocked: return .blocked
        case .done: return .done
        }
    }
}

struct AgentItemKey: Hashable, Codable, Sendable {
    let source: AgentSource
    let sessionID: String
    let itemID: String
}

struct AgentItemSnapshot: Identifiable, Equatable, Sendable {
    let key: AgentItemKey
    let kind: AgentItemKind
    let title: String
    let description: String
    let status: AgentItemStatus
    let sortOrder: Int
    let sourceUpdatedAt: Date?
    let blocks: [String]
    let blockedBy: [String]
    var id: AgentItemKey { key }
}

struct AgentSessionSnapshot: Identifiable, Equatable, Sendable {
    let source: AgentSource
    let sessionID: String
    let title: String
    let updatedAt: Date
    let items: [AgentItemSnapshot]
    var id: String { "\(source.rawValue):\(sessionID)" }
}

struct AgentProjectSnapshot: Identifiable, Equatable, Sendable {
    let source: AgentSource
    let projectKey: String
    let displayName: String
    let cwd: String
    let sessions: [AgentSessionSnapshot]
    var id: String { "\(source.rawValue):\(projectKey)" }
}

struct AgentSnapshot: Equatable, Sendable {
    let source: AgentSource
    let scannedAt: Date
    let projects: [AgentProjectSnapshot]
    let cursorData: String?
}

struct AgentSourceState: Equatable, Sendable {
    let source: AgentSource
    let lastScanAt: Date?
    let lastSuccessAt: Date?
    let error: String?
}

struct AgentDashboard: Equatable, Sendable {
    let projects: [AgentProjectSnapshot]
    let sourceStates: [AgentSourceState]
    let adoptions: [AgentItemKey: AgentAdoptionRecord]

    var adoptedKeys: Set<AgentItemKey> { Set(adoptions.keys) }
}

enum AgentAdoptionState: String, Codable, Sendable { case pending, completed, failed }
struct AgentAdoptionRecord: Equatable, Sendable {
    let key: AgentItemKey
    let progressBarTaskID: String
    let targetSectionID: String
    let state: AgentAdoptionState
    let adoptedAt: Date
}

enum AgentAdoptionPresentation: Equatable, Sendable {
    case available
    case retry(taskID: String)
    case adopted(taskID: String)
    case adoptedTaskMissing(taskID: String)
}

protocol AgentConnector: Sendable {
    var source: AgentSource { get }
    func scan(cursor: String?) async throws -> AgentSnapshot
}
