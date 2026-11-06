import Foundation
import SQLite3

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum SQLiteValue {
    case text(String)
    case integer(Int64)
    case null
}

final class ProjectWriterLock {
    private let descriptor: Int32

    init(root: URL) throws {
        let lockURL = root.appendingPathComponent(
            ".aivideo-writer.lock"
        )

        let fd = open(
            lockURL.path,
            O_RDWR | O_CREAT | O_CLOEXEC,
            0o600
        )

        guard fd >= 0 else {
            throw ProjectStoreError.projectLocked
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(fd)
            throw ProjectStoreError.projectLocked
        }

        descriptor = fd
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

final class SQLiteStoreDatabase {
    private var handle: OpaquePointer?
    private let writerLock: ProjectWriterLock

    init(
        projectRoot: URL,
        migrationsDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: true
        )

        writerLock = try ProjectWriterLock(root: projectRoot)

        let filename = projectRoot.appendingPathComponent(
            "canonical.sqlite"
        )

        let flags = SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_CREATE
            | SQLITE_OPEN_FULLMUTEX

        let openCode = sqlite3_open_v2(
            filename.path,
            &handle,
            flags,
            nil
        )

        guard openCode == SQLITE_OK else {
            let message = handle.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "cannot open database"

            if let handle {
                sqlite3_close_v2(handle)
            }

            handle = nil

            throw ProjectStoreError.database(
                code: openCode,
                message: message
            )
        }

        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 1000)

        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")

            let version = Int(
                try scalarInt("PRAGMA user_version") ?? 0
            )

            guard version <= 2 else {
                throw ProjectStoreError.unsupportedSchema(
                    version: version
                )
            }

            if version < 1 {
                let sql = try String(
                    contentsOf: migrationsDirectory
                        .appendingPathComponent(
                            "001_initial_g1_schema.sql"
                        ),
                    encoding: .utf8
                )
                try execute(sql)
            }

            if version < 2 {
                let sql = try String(
                    contentsOf: migrationsDirectory
                        .appendingPathComponent(
                            "002_s06_editor.sql"
                        ),
                    encoding: .utf8
                )

                try transaction {
                    try execute(sql)
                    try execute("PRAGMA user_version=2")
                }
            }

            // Migration 001 sets NORMAL.
            // Canonical commits must use FULL.
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA foreign_keys=ON")

            guard try scalarInt(
                "PRAGMA foreign_keys"
            ) == 1 else {
                throw ProjectStoreError.database(
                    code: SQLITE_ERROR,
                    message: "Foreign keys disabled"
                )
            }

            guard try scalarInt(
                "PRAGMA synchronous"
            ) == 2 else {
                throw ProjectStoreError.database(
                    code: SQLITE_ERROR,
                    message: "Synchronous FULL not active"
                )
            }
        } catch {
            if let handle {
                sqlite3_close_v2(handle)
            }
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle {
            _ = sqlite3_close_v2(handle)
        }
    }

    private func error(_ code: Int32) -> ProjectStoreError {
        ProjectStoreError.database(
            code: code,
            message: handle.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "database closed"
        )
    }

    private func withStatement<T>(
        _ sql: String,
        values: [SQLiteValue],
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?

        let code = sqlite3_prepare_v2(
            handle,
            sql,
            -1,
            &statement,
            nil
        )

        guard code == SQLITE_OK,
              let stmt = statement else {
            throw error(code)
        }

        defer { sqlite3_finalize(stmt) }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32

            switch value {
            case .text(let str):
                result = str.withCString { ptr in
                    sqlite3_bind_text(
                        stmt,
                        position,
                        ptr,
                        -1,
                        unsafeBitCast(
                            -1,
                            to: sqlite3_destructor_type.self
                        )
                    )
                }

            case .integer(let n):
                result = sqlite3_bind_int64(
                    stmt,
                    position,
                    n
                )

            case .null:
                result = sqlite3_bind_null(
                    stmt,
                    position
                )
            }

            guard result == SQLITE_OK else {
                throw error(result)
            }
        }

        return try body(stmt)
    }

    func execute(
        _ sql: String,
        _ values: [SQLiteValue] = []
    ) throws {
        if values.isEmpty {
            var errorPointer: UnsafeMutablePointer<CChar>?

            let code = sqlite3_exec(
                handle,
                sql,
                nil,
                nil,
                &errorPointer
            )

            defer { sqlite3_free(errorPointer) }

            guard code == SQLITE_OK else {
                throw error(code)
            }
        } else {
            try withStatement(sql, values: values) { stmt in
                let code = sqlite3_step(stmt)

                guard code == SQLITE_DONE else {
                    throw error(code)
                }
            }
        }
    }

    func rows(
        _ sql: String,
        _ values: [SQLiteValue] = []
    ) throws -> [[String: String]] {
        try withStatement(sql, values: values) { stmt in
            var results: [[String: String]] = []

            while true {
                let result = sqlite3_step(stmt)

                if result == SQLITE_DONE {
                    break
                }

                guard result == SQLITE_ROW else {
                    throw error(result)
                }

                var row: [String: String] = [:]

                for i in 0..<sqlite3_column_count(stmt) {
                    guard let field = sqlite3_column_name(
                        stmt,
                        i
                    ) else {
                        continue
                    }

                    guard let data = sqlite3_column_text(
                        stmt,
                        i
                    ) else {
                        continue
                    }

                    row[String(cString: field)] =
                        String(cString: data)
                }

                results.append(row)
            }

            return results
        }
    }

    func scalarInt(
        _ sql: String,
        _ values: [SQLiteValue] = []
    ) throws -> Int64? {
        try rows(sql, values).first?
            .values.first.flatMap(Int64.init)
    }

    func changes() -> Int {
        Int(sqlite3_changes(handle))
    }

    func transaction<T>(
        _ operation: () throws -> T
    ) throws -> T {
        var attempt = 0

        while true {
            do {
                try execute("BEGIN IMMEDIATE")
                break
            } catch let ProjectStoreError.database(
                code, _
            ) where code == SQLITE_BUSY || code == SQLITE_LOCKED {
                attempt += 1

                if attempt >= 3 {
                    throw error(code)
                }
            }
        }

        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func diagnostics() throws -> StoreDiagnostics {
        StoreDiagnostics(
            journalMode: try rows(
                "PRAGMA journal_mode"
            ).first?.values.first ?? "unknown",
            synchronous: Int(
                try scalarInt("PRAGMA synchronous") ?? -1
            ),
            foreignKeys: (
                try scalarInt("PRAGMA foreign_keys") ?? 0
            ) == 1,
            schemaVersion: Int(
                try scalarInt("PRAGMA user_version") ?? -1
            )
        )
    }
}
