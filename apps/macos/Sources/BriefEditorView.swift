import SwiftUI

@MainActor
public final class BriefEditorModel: ObservableObject {
    @Published public private(set) var draftText = ""
    @Published public private(set) var phase: SavePhase = .idle
    @Published public private(set) var workdayRevision = 1

    private let store: ProjectStore
    private let workdayID: UUID

    private var inFlight: (
        text: String,
        id: String,
        revision: Int
    )?

    private var currentlySaving = false
    private var didLoad = false

    public init(
        store: ProjectStore,
        workdayID: UUID
    ) {
        self.store = store
        self.workdayID = workdayID
    }

    public func load() async {
        guard !didLoad else { return }
        didLoad = true

        do {
            let current = try await store.currentBrief(
                workdayID
            )

            workdayRevision = try await store.workdayRevision(
                workdayID
            )

            if case .idle = phase {
                draftText = current?.text ?? ""
                phase = .saved(revision: workdayRevision)
            } else {
                phase = .pending
            }
        } catch {
            didLoad = false
            phase = .failed(
                message: error.localizedDescription
            )
        }
    }

    public func changeText(_ value: String) {
        draftText = value

        // Do not discard an uncertain in-flight operation.
        phase = .pending
    }

    @discardableResult
    public func flush() async -> Bool {
        guard !currentlySaving else {
            return false
        }

        if inFlight == nil {
            if case .saved = phase {
                return true
            }

            inFlight = (
                draftText,
                UUID().uuidString,
                workdayRevision
            )
        }

        guard let request = inFlight else {
            return false
        }

        currentlySaving = true
        phase = .saving

        defer {
            currentlySaving = false
        }

        do {
            let receipt = try await store.saveBrief(
                workdayID: workdayID,
                expectedRevision: request.revision,
                text: request.text,
                operationID: request.id
            )

            workdayRevision = receipt.committedRevision
            inFlight = nil

            phase = draftText == request.text
                ? .saved(revision: receipt.committedRevision)
                : .pending

            return true
        } catch {
            // Keep the exact request for a safe retry.
            phase = .failed(
                message: error.localizedDescription
            )

            return false
        }
    }

    /// Await before navigation, project switch or approval.
    public func flushBeforeLeaving() async -> Bool {
        for _ in 0..<3 {
            guard await flush() else {
                return false
            }

            if case .saved = phase {
                return true
            }
        }

        return false
    }
}

public struct BriefEditorView: View {
    @ObservedObject private var model: BriefEditorModel

    public init(model: BriefEditorModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Brief ngày làm việc")
                .font(.headline)

            TextEditor(
                text: Binding(
                    get: {
                        model.draftText
                    },
                    set: {
                        model.changeText($0)
                    }
                )
            )
            .frame(minHeight: 130)
            .border(Color.gray.opacity(0.3))

            HStack {
                switch model.phase {
                case .idle:
                    Text("Chưa tải")

                case .pending:
                    Label(
                        "Có thay đổi chưa lưu",
                        systemImage: "circle.dotted"
                    )

                case .saving:
                    Label(
                        "Đang lưu...",
                        systemImage: "arrow.triangle.2.circlepath"
                    )

                case .saved(let revision):
                    Label(
                        "Đã lưu · revision \(revision)",
                        systemImage: "checkmark.circle"
                    )

                case .failed(let message):
                    Label(
                        "Lưu lỗi: \(message)",
                        systemImage: "exclamationmark.triangle"
                    )
                }

                Spacer()

                Button("Lưu") {
                    Task {
                        await model.flush()
                    }
                }
            }
            .font(.caption)
        }
        .task {
            await model.load()
        }
    }
}
