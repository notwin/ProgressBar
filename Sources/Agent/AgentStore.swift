import CryptoKit
import Foundation
import SQLite3

enum AgentStoreError: Error, CustomStringConvertible {
    case sqlite(code: Int32, context: String, message: String)
    case unsupportedSchema(Int)
    case invalidData(String)

    var description: String {
        switch self {
        case let .sqlite(code, context, message):
            return "SQLite error \(code) during \(context): \(message)"
        case let .unsupportedSchema(version):
            return "Unsupported agent store schema version: \(version)"
        case let .invalidData(message):
            return "Invalid agent store data: \(message)"
        }
    }

    var isCorruption: Bool {
        guard case let .sqlite(code, _, _) = self else { return false }
        return code == SQLITE_CORRUPT || code == SQLITE_NOTADB
    }
}

actor AgentStore {
    private static let connectorVersion = "1"

    nonisolated(unsafe) private let database: OpaquePointer

    init(
        databaseURL: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws {
        database = try Self.openDatabase(at: databaseURL, now: now)
    }

    deinit {
        sqlite3_close(database)
    }

    func apply(snapshot: AgentSnapshot) throws {
        try Self.executeSQL(database, "BEGIN IMMEDIATE", context: "begin snapshot transaction")
        var committed = false
        defer {
            if !committed {
                try? Self.executeSQL(database, "ROLLBACK", context: "rollback snapshot transaction")
            }
        }

        let scannedAt = snapshot.scannedAt.timeIntervalSince1970
        do {
            try Self.executeSQL(
                database,
                "CREATE TEMP TABLE IF NOT EXISTS agent_seen_items(id TEXT PRIMARY KEY)",
                context: "create seen-items table"
            )
            try Self.executeSQL(database, "DELETE FROM agent_seen_items", context: "clear seen-items table")

            let projectStatement = try SQLiteStatement(
                database: database,
                sql: """
                INSERT INTO agent_projects(
                  id, source, source_project_key, display_name, cwd, last_seen_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, source_project_key) DO UPDATE SET
                  display_name = excluded.display_name,
                  cwd = excluded.cwd,
                  last_seen_at = excluded.last_seen_at
                """
            )
            let sessionStatement = try SQLiteStatement(
                database: database,
                sql: """
                INSERT INTO agent_sessions(
                  id, project_id, source, source_session_id, title,
                  source_updated_at, last_seen_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, source_session_id) DO UPDATE SET
                  project_id = excluded.project_id,
                  title = excluded.title,
                  source_updated_at = excluded.source_updated_at,
                  last_seen_at = excluded.last_seen_at
                """
            )
            let itemStatement = try SQLiteStatement(
                database: database,
                sql: """
                INSERT INTO agent_items(
                  id, session_id, source, source_session_id, source_item_id,
                  kind, title, description, status, sort_order,
                  source_updated_at, last_seen_at, completed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source, source_session_id, source_item_id) DO UPDATE SET
                  session_id = excluded.session_id,
                  kind = excluded.kind,
                  title = excluded.title,
                  description = excluded.description,
                  status = excluded.status,
                  sort_order = excluded.sort_order,
                  source_updated_at = excluded.source_updated_at,
                  last_seen_at = excluded.last_seen_at,
                  completed_at = CASE
                    WHEN excluded.status = 'done'
                    THEN COALESCE(agent_items.completed_at, excluded.completed_at)
                    ELSE NULL
                  END
                """
            )
            let seenStatement = try SQLiteStatement(
                database: database,
                sql: "INSERT OR IGNORE INTO agent_seen_items(id) VALUES (?)"
            )
            let deleteLinksStatement = try SQLiteStatement(
                database: database,
                sql: "DELETE FROM agent_item_links WHERE item_id = ?"
            )
            let insertLinkStatement = try SQLiteStatement(
                database: database,
                sql: """
                INSERT OR IGNORE INTO agent_item_links(
                  item_id, related_source_item_id, relation
                ) VALUES (?, ?, ?)
                """
            )

            for project in snapshot.projects {
                let projectID = Self.stableUUID(
                    for: "project|\(snapshot.source.rawValue)|\(project.projectKey)"
                )
                try projectStatement.run { statement in
                    try statement.bind(projectID, at: 1)
                    try statement.bind(snapshot.source.rawValue, at: 2)
                    try statement.bind(project.projectKey, at: 3)
                    try statement.bind(project.displayName, at: 4)
                    try statement.bind(project.cwd, at: 5)
                    try statement.bind(scannedAt, at: 6)
                }

                for session in project.sessions {
                    let sessionID = Self.stableUUID(
                        for: "session|\(snapshot.source.rawValue)|\(session.sessionID)"
                    )
                    try sessionStatement.run { statement in
                        try statement.bind(sessionID, at: 1)
                        try statement.bind(projectID, at: 2)
                        try statement.bind(snapshot.source.rawValue, at: 3)
                        try statement.bind(session.sessionID, at: 4)
                        try statement.bind(session.title, at: 5)
                        try statement.bind(session.updatedAt.timeIntervalSince1970, at: 6)
                        try statement.bind(scannedAt, at: 7)
                    }

                    for item in session.items {
                        let itemID = Self.stableUUID(
                            for: "item|\(snapshot.source.rawValue)|\(session.sessionID)|\(item.key.itemID)"
                        )
                        let completedAt: Double? = item.status == .done ? scannedAt : nil
                        try itemStatement.run { statement in
                            try statement.bind(itemID, at: 1)
                            try statement.bind(sessionID, at: 2)
                            try statement.bind(snapshot.source.rawValue, at: 3)
                            try statement.bind(session.sessionID, at: 4)
                            try statement.bind(item.key.itemID, at: 5)
                            try statement.bind(item.kind.rawValue, at: 6)
                            try statement.bind(item.title, at: 7)
                            try statement.bind(item.description, at: 8)
                            try statement.bind(item.status.rawValue, at: 9)
                            try statement.bind(item.sortOrder, at: 10)
                            try statement.bind(item.sourceUpdatedAt?.timeIntervalSince1970, at: 11)
                            try statement.bind(scannedAt, at: 12)
                            try statement.bind(completedAt, at: 13)
                        }
                        try seenStatement.run { statement in
                            try statement.bind(itemID, at: 1)
                        }
                        try deleteLinksStatement.run { statement in
                            try statement.bind(itemID, at: 1)
                        }
                        for relatedItemID in item.blocks {
                            try insertLinkStatement.run { statement in
                                try statement.bind(itemID, at: 1)
                                try statement.bind(relatedItemID, at: 2)
                                try statement.bind("blocks", at: 3)
                            }
                        }
                        for relatedItemID in item.blockedBy {
                            try insertLinkStatement.run { statement in
                                try statement.bind(itemID, at: 1)
                                try statement.bind(relatedItemID, at: 2)
                                try statement.bind("blocked_by", at: 3)
                            }
                        }
                    }
                }
            }

            let markMissingStatement = try SQLiteStatement(
                database: database,
                sql: """
                UPDATE agent_items
                SET status = 'done', completed_at = COALESCE(completed_at, ?)
                WHERE source = ?
                  AND id NOT IN (SELECT id FROM agent_seen_items)
                """
            )
            try markMissingStatement.run { statement in
                try statement.bind(scannedAt, at: 1)
                try statement.bind(snapshot.source.rawValue, at: 2)
            }

            let stateStatement = try SQLiteStatement(
                database: database,
                sql: """
                INSERT INTO agent_scan_state(
                  source, connector_version, last_scan_at, last_success_at,
                  last_error, cursor_data
                ) VALUES (?, ?, ?, ?, NULL, ?)
                ON CONFLICT(source) DO UPDATE SET
                  connector_version = excluded.connector_version,
                  last_scan_at = excluded.last_scan_at,
                  last_success_at = excluded.last_success_at,
                  last_error = NULL,
                  cursor_data = excluded.cursor_data
                """
            )
            try stateStatement.run { statement in
                try statement.bind(snapshot.source.rawValue, at: 1)
                try statement.bind(Self.connectorVersion, at: 2)
                try statement.bind(scannedAt, at: 3)
                try statement.bind(scannedAt, at: 4)
                try statement.bind(snapshot.cursorData, at: 5)
            }

            try Self.executeSQL(database, "COMMIT", context: "commit snapshot transaction")
            committed = true
        } catch {
            throw error
        }
    }

    func recordFailure(source: AgentSource, message: String, at: Date) throws {
        let statement = try SQLiteStatement(
            database: database,
            sql: """
            INSERT INTO agent_scan_state(
              source, connector_version, last_scan_at, last_success_at,
              last_error, cursor_data
            ) VALUES (?, ?, ?, NULL, ?, NULL)
            ON CONFLICT(source) DO UPDATE SET
              connector_version = excluded.connector_version,
              last_scan_at = excluded.last_scan_at,
              last_error = excluded.last_error
            """
        )
        try statement.run { statement in
            try statement.bind(source.rawValue, at: 1)
            try statement.bind(Self.connectorVersion, at: 2)
            try statement.bind(at.timeIntervalSince1970, at: 3)
            try statement.bind(message, at: 4)
        }
    }

    func cursor(for source: AgentSource) throws -> String? {
        let statement = try SQLiteStatement(
            database: database,
            sql: "SELECT cursor_data FROM agent_scan_state WHERE source = ?"
        )
        try statement.bind(source.rawValue, at: 1)
        guard try statement.step() else { return nil }
        return statement.optionalText(at: 0)
    }

    func dashboard(includeHistory: Bool) throws -> AgentDashboard {
        let links = try readLinks()
        let statement = try SQLiteStatement(
            database: database,
            sql: """
            SELECT
              p.id, p.source, p.source_project_key, p.display_name, p.cwd,
              s.id, s.source_session_id, s.title, s.source_updated_at,
              i.id, i.source_item_id, i.kind, i.title, i.description,
              i.status, i.sort_order, i.source_updated_at
            FROM agent_items i
            JOIN agent_sessions s ON s.id = i.session_id
            JOIN agent_projects p ON p.id = s.project_id
            WHERE ? = 1 OR i.status != 'done'
            """
        )
        try statement.bind(includeHistory ? 1 : 0, at: 1)

        var rows: [StoredDashboardRow] = []
        while try statement.step() {
            guard
                let source = AgentSource(rawValue: statement.text(at: 1)),
                let kind = AgentItemKind(rawValue: statement.text(at: 11)),
                let status = AgentItemStatus(rawValue: statement.text(at: 14))
            else {
                throw AgentStoreError.invalidData("unknown source, item kind, or item status")
            }
            let itemDatabaseID = statement.text(at: 9)
            let itemLinks = links[itemDatabaseID] ?? StoredLinks()
            rows.append(
                StoredDashboardRow(
                    projectID: statement.text(at: 0),
                    source: source,
                    projectKey: statement.text(at: 2),
                    displayName: statement.text(at: 3),
                    cwd: statement.text(at: 4),
                    sessionDatabaseID: statement.text(at: 5),
                    sessionID: statement.text(at: 6),
                    sessionTitle: statement.text(at: 7),
                    sessionUpdatedAt: Date(timeIntervalSince1970: statement.double(at: 8)),
                    item: AgentItemSnapshot(
                        key: AgentItemKey(
                            source: source,
                            sessionID: statement.text(at: 6),
                            itemID: statement.text(at: 10)
                        ),
                        kind: kind,
                        title: statement.text(at: 12),
                        description: statement.text(at: 13),
                        status: status,
                        sortOrder: statement.integer(at: 15),
                        sourceUpdatedAt: statement.optionalDouble(at: 16).map(Date.init(timeIntervalSince1970:)),
                        blocks: itemLinks.blocks,
                        blockedBy: itemLinks.blockedBy
                    )
                )
            )
        }

        let projectGroups = Dictionary(grouping: rows, by: \.projectID)
        let projects = projectGroups.values.map { projectRows -> (Date, AgentProjectSnapshot) in
            let first = projectRows[0]
            let sessionGroups = Dictionary(grouping: projectRows, by: \.sessionDatabaseID)
            let sessions = sessionGroups.values.map { sessionRows -> AgentSessionSnapshot in
                let session = sessionRows[0]
                let items = sessionRows.map(\.item).sorted {
                    if $0.sortOrder == $1.sortOrder { return $0.key.itemID < $1.key.itemID }
                    return $0.sortOrder < $1.sortOrder
                }
                return AgentSessionSnapshot(
                    source: session.source,
                    sessionID: session.sessionID,
                    title: session.sessionTitle,
                    updatedAt: session.sessionUpdatedAt,
                    items: items
                )
            }.sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt > $1.updatedAt
            }
            let newestUpdate = sessions.map(\.updatedAt).max() ?? .distantPast
            return (
                newestUpdate,
                AgentProjectSnapshot(
                    source: first.source,
                    projectKey: first.projectKey,
                    displayName: first.displayName,
                    cwd: first.cwd,
                    sessions: sessions
                )
            )
        }.sorted {
            if $0.0 == $1.0 { return $0.1.id < $1.1.id }
            return $0.0 > $1.0
        }.map(\.1)

        return AgentDashboard(
            projects: projects,
            sourceStates: try readSourceStates(),
            adoptions: try readAdoptions(),
            hasStoredStructuredItems: try hasStoredStructuredItems()
        )
    }

    func reserveAdoption(
        key: AgentItemKey,
        taskID: String,
        sectionID: String,
        at: Date
    ) throws -> AgentAdoptionRecord {
        try Self.executeSQL(database, "BEGIN IMMEDIATE", context: "begin adoption transaction")
        var committed = false
        defer {
            if !committed {
                try? Self.executeSQL(database, "ROLLBACK", context: "rollback adoption transaction")
            }
        }

        let statement = try SQLiteStatement(
            database: database,
            sql: """
            INSERT OR IGNORE INTO agent_adoptions(
              source, source_session_id, source_item_id, progressbar_task_id,
              target_section_id, state, adopted_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.run { statement in
            try statement.bind(key.source.rawValue, at: 1)
            try statement.bind(key.sessionID, at: 2)
            try statement.bind(key.itemID, at: 3)
            try statement.bind(taskID, at: 4)
            try statement.bind(sectionID, at: 5)
            try statement.bind(AgentAdoptionState.pending.rawValue, at: 6)
            try statement.bind(at.timeIntervalSince1970, at: 7)
        }
        guard let record = try adoption(for: key) else {
            throw AgentStoreError.invalidData("adoption reservation was not persisted")
        }
        try Self.executeSQL(database, "COMMIT", context: "commit adoption transaction")
        committed = true
        return record
    }

    func completeAdoption(key: AgentItemKey) throws {
        try updateAdoption(key: key, state: .completed)
    }

    func failAdoption(key: AgentItemKey) throws {
        try updateAdoption(key: key, state: .failed)
    }

    func prepareAdoptionRetry(
        key: AgentItemKey,
        sectionID: String
    ) throws -> AgentAdoptionRecord {
        try Self.executeSQL(database, "BEGIN IMMEDIATE", context: "begin adoption retry transaction")
        var committed = false
        defer {
            if !committed {
                try? Self.executeSQL(database, "ROLLBACK", context: "rollback adoption retry transaction")
            }
        }

        let statement = try SQLiteStatement(
            database: database,
            sql: """
            UPDATE agent_adoptions SET target_section_id = ?, state = ?
            WHERE source = ? AND source_session_id = ? AND source_item_id = ?
            """
        )
        try statement.run { statement in
            try statement.bind(sectionID, at: 1)
            try statement.bind(AgentAdoptionState.pending.rawValue, at: 2)
            try statement.bind(key.source.rawValue, at: 3)
            try statement.bind(key.sessionID, at: 4)
            try statement.bind(key.itemID, at: 5)
        }
        guard let record = try adoption(for: key) else {
            throw AgentStoreError.invalidData("adoption retry has no reservation")
        }
        try Self.executeSQL(database, "COMMIT", context: "commit adoption retry transaction")
        committed = true
        return record
    }

    func adoption(for key: AgentItemKey) throws -> AgentAdoptionRecord? {
        let statement = try SQLiteStatement(
            database: database,
            sql: """
            SELECT progressbar_task_id, target_section_id, state, adopted_at
            FROM agent_adoptions
            WHERE source = ? AND source_session_id = ? AND source_item_id = ?
            """
        )
        try statement.bind(key.source.rawValue, at: 1)
        try statement.bind(key.sessionID, at: 2)
        try statement.bind(key.itemID, at: 3)
        guard try statement.step() else { return nil }
        guard let state = AgentAdoptionState(rawValue: statement.text(at: 2)) else {
            throw AgentStoreError.invalidData("unknown adoption state")
        }
        return AgentAdoptionRecord(
            key: key,
            progressBarTaskID: statement.text(at: 0),
            targetSectionID: statement.text(at: 1),
            state: state,
            adoptedAt: Date(timeIntervalSince1970: statement.double(at: 3))
        )
    }

    func pruneHistory(before cutoff: Date) throws {
        try Self.executeSQL(database, "BEGIN IMMEDIATE", context: "begin history prune")
        var committed = false
        defer {
            if !committed {
                try? Self.executeSQL(database, "ROLLBACK", context: "rollback history prune")
            }
        }

        let statement = try SQLiteStatement(
            database: database,
            sql: "DELETE FROM agent_items WHERE status = 'done' AND completed_at < ?"
        )
        try statement.run { statement in
            try statement.bind(cutoff.timeIntervalSince1970, at: 1)
        }
        try Self.executeSQL(
            database,
            "DELETE FROM agent_sessions WHERE NOT EXISTS (SELECT 1 FROM agent_items WHERE session_id = agent_sessions.id)",
            context: "delete empty agent sessions"
        )
        try Self.executeSQL(
            database,
            "DELETE FROM agent_projects WHERE NOT EXISTS (SELECT 1 FROM agent_sessions WHERE project_id = agent_projects.id)",
            context: "delete empty agent projects"
        )
        try Self.executeSQL(database, "COMMIT", context: "commit history prune")
        committed = true
    }

    private func updateAdoption(key: AgentItemKey, state: AgentAdoptionState) throws {
        let statement = try SQLiteStatement(
            database: database,
            sql: """
            UPDATE agent_adoptions SET state = ?
            WHERE source = ? AND source_session_id = ? AND source_item_id = ?
            """
        )
        try statement.run { statement in
            try statement.bind(state.rawValue, at: 1)
            try statement.bind(key.source.rawValue, at: 2)
            try statement.bind(key.sessionID, at: 3)
            try statement.bind(key.itemID, at: 4)
        }
    }

    private func readLinks() throws -> [String: StoredLinks] {
        let statement = try SQLiteStatement(
            database: database,
            sql: "SELECT item_id, related_source_item_id, relation FROM agent_item_links"
        )
        var links: [String: StoredLinks] = [:]
        while try statement.step() {
            let itemID = statement.text(at: 0)
            let relatedID = statement.text(at: 1)
            switch statement.text(at: 2) {
            case "blocks": links[itemID, default: StoredLinks()].blocks.append(relatedID)
            case "blocked_by": links[itemID, default: StoredLinks()].blockedBy.append(relatedID)
            default: throw AgentStoreError.invalidData("unknown item link relation")
            }
        }
        for itemID in links.keys {
            links[itemID]?.blocks.sort()
            links[itemID]?.blockedBy.sort()
        }
        return links
    }

    private func readSourceStates() throws -> [AgentSourceState] {
        let statement = try SQLiteStatement(
            database: database,
            sql: "SELECT source, last_scan_at, last_success_at, last_error FROM agent_scan_state"
        )
        var stored: [AgentSource: AgentSourceState] = [:]
        while try statement.step() {
            guard let source = AgentSource(rawValue: statement.text(at: 0)) else {
                throw AgentStoreError.invalidData("unknown scan-state source")
            }
            stored[source] = AgentSourceState(
                source: source,
                lastScanAt: statement.optionalDouble(at: 1).map(Date.init(timeIntervalSince1970:)),
                lastSuccessAt: statement.optionalDouble(at: 2).map(Date.init(timeIntervalSince1970:)),
                error: statement.optionalText(at: 3)
            )
        }
        return AgentSource.allCases.map { source in
            stored[source] ?? AgentSourceState(
                source: source,
                lastScanAt: nil,
                lastSuccessAt: nil,
                error: nil
            )
        }
    }

    private func hasStoredStructuredItems() throws -> Bool {
        let statement = try SQLiteStatement(
            database: database,
            sql: "SELECT EXISTS(SELECT 1 FROM agent_items LIMIT 1)"
        )
        guard try statement.step() else {
            throw AgentStoreError.invalidData("structured-item existence query returned no row")
        }
        return statement.integer(at: 0) != 0
    }

    private func readAdoptions() throws -> [AgentItemKey: AgentAdoptionRecord] {
        let statement = try SQLiteStatement(
            database: database,
            sql: """
            SELECT source, source_session_id, source_item_id, progressbar_task_id,
                   target_section_id, state, adopted_at
            FROM agent_adoptions
            """
        )
        var adoptions: [AgentItemKey: AgentAdoptionRecord] = [:]
        while try statement.step() {
            guard let source = AgentSource(rawValue: statement.text(at: 0)),
                  let state = AgentAdoptionState(rawValue: statement.text(at: 5))
            else {
                throw AgentStoreError.invalidData("unknown adoption source or state")
            }
            let key = AgentItemKey(
                source: source,
                sessionID: statement.text(at: 1),
                itemID: statement.text(at: 2)
            )
            adoptions[key] = AgentAdoptionRecord(
                key: key,
                progressBarTaskID: statement.text(at: 3),
                targetSectionID: statement.text(at: 4),
                state: state,
                adoptedAt: Date(timeIntervalSince1970: statement.double(at: 6))
            )
        }
        return adoptions
    }

    private static func openDatabase(
        at databaseURL: URL,
        now: @escaping @Sendable () -> Date
    ) throws -> OpaquePointer {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        for attempt in 0 ... 1 {
            do {
                return try openConfiguredDatabase(at: databaseURL)
            } catch let error as AgentStoreError where error.isCorruption && attempt == 0 {
                guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw error }
                let timestamp = Int(now().timeIntervalSince1970)
                var backupURL = databaseURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(databaseURL.lastPathComponent).corrupt.\(timestamp)")
                var suffix = 1
                while FileManager.default.fileExists(atPath: backupURL.path) {
                    backupURL = databaseURL
                        .deletingLastPathComponent()
                        .appendingPathComponent("\(databaseURL.lastPathComponent).corrupt.\(timestamp).\(suffix)")
                    suffix += 1
                }
                try FileManager.default.moveItem(at: databaseURL, to: backupURL)
            }
        }
        throw AgentStoreError.invalidData("database recovery exhausted")
    }

    private static func openConfiguredDatabase(at databaseURL: URL) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        guard result == SQLITE_OK, let database = handle else {
            let error = sqliteError(
                database: handle,
                code: result,
                context: "open database"
            )
            if let handle { sqlite3_close(handle) }
            throw error
        }

        do {
            try executeSQL(database, "PRAGMA foreign_keys = ON", context: "enable foreign keys")
            try verifyIntegrity(database)
            try migrate(database)
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private static func verifyIntegrity(_ database: OpaquePointer) throws {
        let statement = try SQLiteStatement(database: database, sql: "PRAGMA integrity_check")
        guard try statement.step(), statement.text(at: 0) == "ok" else {
            throw AgentStoreError.sqlite(
                code: SQLITE_CORRUPT,
                context: "integrity check",
                message: "database integrity check did not return ok"
            )
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try executeSQL(database, "BEGIN IMMEDIATE", context: "begin schema migration")
        var committed = false
        defer {
            if !committed {
                try? executeSQL(database, "ROLLBACK", context: "rollback schema migration")
            }
        }

        try executeSQL(
            database,
            "CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL)",
            context: "create schema version table"
        )
        let versionStatement = try SQLiteStatement(
            database: database,
            sql: "SELECT version FROM schema_version LIMIT 1"
        )
        let hasVersion = try versionStatement.step()
        if hasVersion {
            let version = versionStatement.integer(at: 0)
            guard version == 1 else { throw AgentStoreError.unsupportedSchema(version) }
        } else {
            let schemaStatements = [
                """
                CREATE TABLE agent_projects(
                  id TEXT PRIMARY KEY, source TEXT NOT NULL, source_project_key TEXT NOT NULL,
                  display_name TEXT NOT NULL, cwd TEXT NOT NULL, last_seen_at REAL NOT NULL,
                  UNIQUE(source, source_project_key)
                )
                """,
                """
                CREATE TABLE agent_sessions(
                  id TEXT PRIMARY KEY,
                  project_id TEXT NOT NULL REFERENCES agent_projects(id) ON DELETE CASCADE,
                  source TEXT NOT NULL, source_session_id TEXT NOT NULL, title TEXT NOT NULL,
                  source_updated_at REAL NOT NULL, last_seen_at REAL NOT NULL,
                  UNIQUE(source, source_session_id)
                )
                """,
                """
                CREATE TABLE agent_items(
                  id TEXT PRIMARY KEY,
                  session_id TEXT NOT NULL REFERENCES agent_sessions(id) ON DELETE CASCADE,
                  source TEXT NOT NULL, source_session_id TEXT NOT NULL, source_item_id TEXT NOT NULL,
                  kind TEXT NOT NULL, title TEXT NOT NULL, description TEXT NOT NULL,
                  status TEXT NOT NULL, sort_order INTEGER NOT NULL,
                  source_updated_at REAL, last_seen_at REAL NOT NULL, completed_at REAL,
                  UNIQUE(source, source_session_id, source_item_id)
                )
                """,
                """
                CREATE TABLE agent_item_links(
                  item_id TEXT NOT NULL REFERENCES agent_items(id) ON DELETE CASCADE,
                  related_source_item_id TEXT NOT NULL, relation TEXT NOT NULL,
                  UNIQUE(item_id, related_source_item_id, relation)
                )
                """,
                """
                CREATE TABLE agent_adoptions(
                  source TEXT NOT NULL, source_session_id TEXT NOT NULL, source_item_id TEXT NOT NULL,
                  progressbar_task_id TEXT NOT NULL, target_section_id TEXT NOT NULL,
                  state TEXT NOT NULL, adopted_at REAL NOT NULL,
                  UNIQUE(source, source_session_id, source_item_id)
                )
                """,
                """
                CREATE TABLE agent_scan_state(
                  source TEXT PRIMARY KEY, connector_version TEXT NOT NULL,
                  last_scan_at REAL, last_success_at REAL, last_error TEXT, cursor_data TEXT
                )
                """
            ]
            for sql in schemaStatements {
                try executeSQL(database, sql, context: "create schema version 1")
            }
            try executeSQL(database, "INSERT INTO schema_version(version) VALUES (1)", context: "record schema version")
        }
        try executeSQL(database, "COMMIT", context: "commit schema migration")
        committed = true
    }

    private static func executeSQL(
        _ database: OpaquePointer,
        _ sql: String,
        context: String
    ) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw AgentStoreError.sqlite(code: result, context: context, message: message)
        }
    }

    private static func sqliteError(
        database: OpaquePointer?,
        code: Int32,
        context: String
    ) -> AgentStoreError {
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "SQLite did not return a database handle"
        return .sqlite(code: code, context: context, message: message)
    }

    private static func stableUUID(for value: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [
            String(hex.prefix(8)),
            String(hex.dropFirst(8).prefix(4)),
            String(hex.dropFirst(12).prefix(4)),
            String(hex.dropFirst(16).prefix(4)),
            String(hex.dropFirst(20).prefix(12))
        ].joined(separator: "-")
    }
}

private struct StoredDashboardRow {
    let projectID: String
    let source: AgentSource
    let projectKey: String
    let displayName: String
    let cwd: String
    let sessionDatabaseID: String
    let sessionID: String
    let sessionTitle: String
    let sessionUpdatedAt: Date
    let item: AgentItemSnapshot
}

private struct StoredLinks {
    var blocks: [String] = []
    var blockedBy: [String] = []
}

private final class SQLiteStatement {
    private let database: OpaquePointer
    private let statement: OpaquePointer

    init(database: OpaquePointer, sql: String) throws {
        self.database = database
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else {
            throw AgentStoreError.sqlite(
                code: result,
                context: "prepare statement",
                message: String(cString: sqlite3_errmsg(database))
            )
        }
        statement = prepared
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func run(bindings: (SQLiteStatement) throws -> Void) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bindings(self)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw sqliteError(code: result, context: "execute statement")
        }
    }

    func bind(_ value: String, at index: Int32) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        guard result == SQLITE_OK else { throw sqliteError(code: result, context: "bind text") }
    }

    func bind(_ value: String?, at index: Int32) throws {
        guard let value else { return try bindNull(at: index) }
        try bind(value, at: index)
    }

    func bind(_ value: Double, at index: Int32) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else { throw sqliteError(code: result, context: "bind double") }
    }

    func bind(_ value: Double?, at index: Int32) throws {
        guard let value else { return try bindNull(at: index) }
        try bind(value, at: index)
    }

    func bind(_ value: Int, at index: Int32) throws {
        let result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
        guard result == SQLITE_OK else { throw sqliteError(code: result, context: "bind integer") }
    }

    func step() throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw sqliteError(code: result, context: "read statement")
        }
    }

    func text(at index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    func optionalText(at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(at: index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func optionalDouble(at index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return double(at: index)
    }

    func integer(at index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    private func bindNull(at index: Int32) throws {
        let result = sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw sqliteError(code: result, context: "bind null") }
    }

    private func sqliteError(code: Int32, context: String) -> AgentStoreError {
        .sqlite(
            code: code,
            context: context,
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}

private var sqliteTransient: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
