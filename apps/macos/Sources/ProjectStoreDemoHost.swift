import SwiftUI

/// Minimal S06 editor host.
/// Full project navigation comes in later UI steps.
public struct ProjectStoreDemoHost: View {
    @State private var editor: BriefEditorModel?
    @State private var loadError: String?

    public init() {}

    public var body: some View {
        GroupBox(
            label: Label(
                "G1 · ProjectStore — Brief Editor",
                systemImage: "externaldrive"
            )
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let editor {
                    BriefEditorView(model: editor)
                } else if let loadError {
                    Text(loadError)
                        .foregroundColor(.red)

                    Button("Thử lại") {
                        Task {
                            await initialize()
                        }
                    }
                } else {
                    ProgressView(
                        "Đang mở canonical SQLite..."
                    )
                }
            }
            .padding(8)
        }
        .task {
            await initialize()
        }
    }

    @MainActor
    private func initialize() async {
        guard editor == nil else {
            return
        }

        do {
            let defaults = UserDefaults.standard

            let projectID = UUID(
                uuidString: defaults.string(
                    forKey: "S06DemoProjectID"
                ) ?? ""
            ) ?? UUID()

            let workdayID = UUID(
                uuidString: defaults.string(
                    forKey: "S06DemoWorkdayID"
                ) ?? ""
            ) ?? UUID()

            defaults.set(
                projectID.uuidString,
                forKey: "S06DemoProjectID"
            )

            defaults.set(
                workdayID.uuidString,
                forKey: "S06DemoWorkdayID"
            )

            let firstDate = defaults.string(
                forKey: "S06DemoWorkdayDate"
            ) ?? String(
                ISO8601DateFormatter()
                    .string(from: Date())
                    .prefix(10)
            )

            defaults.set(
                firstDate,
                forKey: "S06DemoWorkdayDate"
            )

            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw ProjectStoreError.notFound(
                    "Application Support"
                )
            }

            let projectRoot = appSupport.appendingPathComponent(
                "AIVideo/Projects/\(projectID.uuidString)",
                isDirectory: true
            )

            guard let migrationDir = Bundle.main.resourceURL?
                .appendingPathComponent(
                    "contracts/migrations",
                    isDirectory: true
                ) else {
                throw ProjectStoreError.notFound(
                    "Bundled S06 migrations"
                )
            }

            let store = try await ProjectStoreRegistry.shared.open(
                projectRoot: projectRoot,
                migrationsDirectory: migrationDir
            )

            _ = try await store.createProject(
                projectID: projectID,
                name: "AIVideo Local Project",
                operationID: "bootstrap-project-\(projectID.uuidString)"
            )

            _ = try await store.createWorkday(
                workdayID: workdayID,
                projectID: projectID,
                title: "Ngày làm việc",
                date: firstDate,
                operationID: "bootstrap-workday-\(workdayID.uuidString)"
            )

            editor = BriefEditorModel(
                store: store,
                workdayID: workdayID
            )

            loadError = nil
        } catch {
            loadError = "Không thể mở S06: \(error.localizedDescription)"
        }
    }
}
