import Foundation

/// Share exactly one ProjectStore actor between windows.
public actor ProjectStoreRegistry {
    public static let shared = ProjectStoreRegistry()

    private var opened: [String: ProjectStore] = [:]

    public func open(
        projectRoot: URL,
        migrationsDirectory: URL
    ) throws -> ProjectStore {
        let key = projectRoot.standardizedFileURL
            .resolvingSymlinksInPath().path

        if let existing = opened[key] {
            return existing
        }

        let store = try ProjectStore(
            projectRoot: projectRoot,
            migrationsDirectory: migrationsDirectory
        )

        opened[key] = store
        return store
    }

    public func close(projectRoot: URL) {
        let key = projectRoot.standardizedFileURL
            .resolvingSymlinksInPath().path

        opened.removeValue(forKey: key)
    }
}
