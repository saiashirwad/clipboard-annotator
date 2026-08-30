import AppKit
import Combine

/// State for one capture, owned by the controller rather than the view.
///
/// The note used to live in `@State` inside the view, and ⌘↩ reached it through
/// a NotificationCenter broadcast. Any view instance that outlived its panel
/// also heard that broadcast and saved its stale annotation again, so an old
/// note would reappear at the end of the stack on every save. The controller
/// now holds the text and saves it directly — nothing is broadcast.
@MainActor
final class CaptureModel: ObservableObject {
    @Published var note: String = ""
    @Published var expanded: Bool = false

    let captured: CapturedSelection
    let stackCount: Int

    init(captured: CapturedSelection, stackCount: Int) {
        self.captured = captured
        self.stackCount = stackCount
    }
}
