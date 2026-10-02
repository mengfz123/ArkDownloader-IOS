import Foundation
import SQLite3

/// SQLite-backed task persistence. All access is serialized through this actor.
actor AppDatabase {
    static let shared = AppDatabase()

    nonisolated(unsafe) private var db: OpaquePointer?

    private init() {
        open()
        createTables()
    }

    nonisolated private func open() {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let docs = paths[0]
        let dbURL = docs.appendingPathComponent("ark_downloader.sqlite")
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("ArkDB: failed to open database")
        }
    }

    nonisolated private func createTables() {
        let tasksSQL = """
        CREATE TABLE IF NOT EXISTS tasks (
            id TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            fileName TEXT NOT NULL,
            saveDir TEXT NOT NULL,
            filePath TEXT NOT NULL,
            stagingPath TEXT NOT NULL,
            totalSize INTEGER NOT NULL,
            loaded INTEGER NOT NULL,
            speed INTEGER NOT NULL,
            status TEXT NOT NULL,
            errorMsg TEXT,
            threads INTEGER NOT NULL,
            chunkSize INTEGER NOT NULL,
            userAgent TEXT,
            headersJson TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            startedAt INTEGER,
            completedAt INTEGER,
            isFolder INTEGER NOT NULL DEFAULT 0,
            folderChildrenJson TEXT NOT NULL DEFAULT '[]',
            currentFileName TEXT,
            filesCompleted INTEGER NOT NULL DEFAULT 0,
            filesTotal INTEGER NOT NULL DEFAULT 0
        );
        """
        let chunksSQL = """
        CREATE TABLE IF NOT EXISTS chunks (
            taskId TEXT NOT NULL,
            \"index\" INTEGER NOT NULL,
            start INTEGER NOT NULL,
            \"end\" INTEGER NOT NULL,
            loaded INTEGER NOT NULL,
            completed INTEGER NOT NULL,
            partPath TEXT NOT NULL,
            PRIMARY KEY (taskId, \"index\")
        );
        """
        _ = exec(tasksSQL)
        _ = exec(chunksSQL)
    }

    @discardableResult
    nonisolated private func exec(_ sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let msg = errMsg {
                print("ArkDB exec error: \(String(cString: msg))")
                sqlite3_free(errMsg)
            }
            return false
        }
        return true
    }

    // MARK: - Tasks

    func getAll() -> [TaskEntity] {
        let sql = "SELECT * FROM tasks ORDER BY createdAt DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [TaskEntity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(taskFromRow(stmt!))
        }
        return result
    }

    func getById(_ id: String) -> TaskEntity? {
        let sql = "SELECT * FROM tasks WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return taskFromRow(stmt!)
        }
        return nil
    }

    @discardableResult
    func upsert(_ task: TaskEntity) -> Bool {
        let sql = """
        INSERT INTO tasks (id, url, fileName, saveDir, filePath, stagingPath, totalSize, loaded, speed, status,
            errorMsg, threads, chunkSize, userAgent, headersJson, createdAt, startedAt, completedAt,
            isFolder, folderChildrenJson, currentFileName, filesCompleted, filesTotal)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            url=excluded.url, fileName=excluded.fileName, saveDir=excluded.saveDir,
            filePath=excluded.filePath, stagingPath=excluded.stagingPath, totalSize=excluded.totalSize,
            loaded=excluded.loaded, speed=excluded.speed, status=excluded.status, errorMsg=excluded.errorMsg,
            threads=excluded.threads, chunkSize=excluded.chunkSize, userAgent=excluded.userAgent,
            headersJson=excluded.headersJson, startedAt=excluded.startedAt, completedAt=excluded.completedAt,
            isFolder=excluded.isFolder, folderChildrenJson=excluded.folderChildrenJson,
            currentFileName=excluded.currentFileName, filesCompleted=excluded.filesCompleted,
            filesTotal=excluded.filesTotal;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindTask(stmt!, task)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func deleteTaskFully(_ id: String) {
        _ = exec("DELETE FROM tasks WHERE id = '\(id.sqliteEscaped)';")
        deleteChunks(id)
    }

    private func taskFromRow(_ stmt: OpaquePointer) -> TaskEntity {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let url = String(cString: sqlite3_column_text(stmt, 1))
        let fileName = String(cString: sqlite3_column_text(stmt, 2))
        let saveDir = String(cString: sqlite3_column_text(stmt, 3))
        let filePath = String(cString: sqlite3_column_text(stmt, 4))
        let stagingPath = String(cString: sqlite3_column_text(stmt, 5))
        let totalSize = sqlite3_column_int64(stmt, 6)
        let loaded = sqlite3_column_int64(stmt, 7)
        let speed = sqlite3_column_int64(stmt, 8)
        let status = String(cString: sqlite3_column_text(stmt, 9))
        let errorMsg: String? = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        let threads = Int(sqlite3_column_int(stmt, 11))
        let chunkSize = Int(sqlite3_column_int(stmt, 12))
        let userAgent: String? = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
        let headersJson = String(cString: sqlite3_column_text(stmt, 14))
        let createdAt = sqlite3_column_int64(stmt, 15)
        let startedAt: Int64? = sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 16)
        let completedAt: Int64? = sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 17)
        let isFolder = sqlite3_column_int(stmt, 18) != 0
        let folderChildrenJson = String(cString: sqlite3_column_text(stmt, 19))
        let currentFileName: String? = sqlite3_column_text(stmt, 20).map { String(cString: $0) }
        let filesCompleted = Int(sqlite3_column_int(stmt, 21))
        let filesTotal = Int(sqlite3_column_int(stmt, 22))
        return TaskEntity(id: id, url: url, fileName: fileName, saveDir: saveDir, filePath: filePath,
            stagingPath: stagingPath, totalSize: totalSize, loaded: loaded, speed: speed, status: status,
            errorMsg: errorMsg, threads: threads, chunkSize: chunkSize, userAgent: userAgent,
            headersJson: headersJson, createdAt: createdAt, startedAt: startedAt, completedAt: completedAt,
            isFolder: isFolder, folderChildrenJson: folderChildrenJson, currentFileName: currentFileName,
            filesCompleted: filesCompleted, filesTotal: filesTotal)
    }

    private func bindTask(_ stmt: OpaquePointer, _ task: TaskEntity) {
        sqlite3_bind_text(stmt, 1, (task.id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (task.url as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (task.fileName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (task.saveDir as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (task.filePath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (task.stagingPath as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 7, task.totalSize)
        sqlite3_bind_int64(stmt, 8, task.loaded)
        sqlite3_bind_int64(stmt, 9, task.speed)
        sqlite3_bind_text(stmt, 10, (task.status as NSString).utf8String, -1, nil)
        if let err = task.errorMsg { sqlite3_bind_text(stmt, 11, (err as NSString).utf8String, -1, nil) }
        else { sqlite3_bind_null(stmt, 11) }
        sqlite3_bind_int(stmt, 12, Int32(task.threads))
        sqlite3_bind_int(stmt, 13, Int32(task.chunkSize))
        if let ua = task.userAgent { sqlite3_bind_text(stmt, 14, (ua as NSString).utf8String, -1, nil) }
        else { sqlite3_bind_null(stmt, 14) }
        sqlite3_bind_text(stmt, 15, (task.headersJson as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 16, task.createdAt)
        if let s = task.startedAt { sqlite3_bind_int64(stmt, 17, s) } else { sqlite3_bind_null(stmt, 17) }
        if let c = task.completedAt { sqlite3_bind_int64(stmt, 18, c) } else { sqlite3_bind_null(stmt, 18) }
        sqlite3_bind_int(stmt, 19, task.isFolder ? 1 : 0)
        sqlite3_bind_text(stmt, 20, (task.folderChildrenJson as NSString).utf8String, -1, nil)
        if let cf = task.currentFileName { sqlite3_bind_text(stmt, 21, (cf as NSString).utf8String, -1, nil) }
        else { sqlite3_bind_null(stmt, 21) }
        sqlite3_bind_int(stmt, 22, Int32(task.filesCompleted))
        sqlite3_bind_int(stmt, 23, Int32(task.filesTotal))
    }

    // MARK: - Chunks

    func getChunks(_ taskId: String) -> [ChunkEntity] {
        let sql = "SELECT * FROM chunks WHERE taskId = ? ORDER BY \"index\" ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (taskId as NSString).utf8String, -1, nil)
        var result: [ChunkEntity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tid = String(cString: sqlite3_column_text(stmt, 0))
            let index = Int(sqlite3_column_int(stmt, 1))
            let start = sqlite3_column_int64(stmt, 2)
            let end = sqlite3_column_int64(stmt, 3)
            let loaded = sqlite3_column_int64(stmt, 4)
            let completed = sqlite3_column_int(stmt, 5) != 0
            let partPath = String(cString: sqlite3_column_text(stmt, 6))
            result.append(ChunkEntity(taskId: tid, index: index, start: start, end: end,
                loaded: loaded, completed: completed, partPath: partPath))
        }
        return result
    }

    func upsertChunks(_ chunks: [ChunkEntity]) {
        for c in chunks { upsertChunk(c) }
    }

    private func upsertChunk(_ chunk: ChunkEntity) {
        let sql = """
        INSERT INTO chunks (taskId, \"index\", start, \"end\", loaded, completed, partPath)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(taskId, \"index\") DO UPDATE SET
            loaded=excluded.loaded, completed=excluded.completed, partPath=excluded.partPath;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (chunk.taskId as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(chunk.index))
        sqlite3_bind_int64(stmt, 3, chunk.start)
        sqlite3_bind_int64(stmt, 4, chunk.end)
        sqlite3_bind_int64(stmt, 5, chunk.loaded)
        sqlite3_bind_int(stmt, 6, chunk.completed ? 1 : 0)
        sqlite3_bind_text(stmt, 7, (chunk.partPath as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    func deleteChunks(_ taskId: String) {
        _ = exec("DELETE FROM chunks WHERE taskId = '\(taskId.sqliteEscaped)';")
    }
}

extension String {
    var sqliteEscaped: String {
        replacingOccurrences(of: "'", with: "''")
    }
}

