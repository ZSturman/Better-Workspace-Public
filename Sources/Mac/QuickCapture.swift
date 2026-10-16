import SwiftUI
import AppKit
import Carbon.HIToolbox
import BetterWorkspaceCore

/// Fast capture, so ingest beats navigating Finder by a wide margin.
///
/// A floating panel summoned with ⌥⌘Space from anywhere. Type, press Return, it's a
/// Markdown file in the inbox and the panel is gone.
@MainActor
final class QuickCaptureController: NSObject, NSWindowDelegate {
    static let shared = QuickCaptureController()

    private var panel: NSPanel?
    private var hotKeyRef: EventHotKeyRef?
    private weak var model: AppModel?

    func configure(model: AppModel) {
        self.model = model
        registerHotKey()
    }

    // MARK: Panel

    func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    /// `asIdea` (Capture Idea / New Idea) titles the panel accordingly and offers
    /// Ideas first; the composer itself is the same.
    func show(asIdea: Bool = false) {
        guard let model else { return }
        model.captureDraft.ideaRequested = asIdea
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            panel.contentView = NSHostingView(
                rootView: QuickCaptureView(onDismiss: { [weak self] in self?.panel?.orderOut(nil) })
                    .environment(model)
            )
            self.panel = panel
        }
        panel?.center()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        model.captureDraft.focusRequest += 1
    }

    // MARK: Global hot key — ⌥⌘Space

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if hotKeyID.signature == quickCaptureHotKeySignature {
                Task { @MainActor in QuickCaptureController.shared.toggle() }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: quickCaptureHotKeySignature, id: 1)
        RegisterEventHotKey(UInt32(kVK_Space),
                            UInt32(optionKey | cmdKey),
                            hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

}

/// File-scope so the C hot-key callback can reference it — a C function pointer can't
/// capture `Self`.
private let quickCaptureHotKeySignature: OSType = 0x42575343 // 'BWSC'


struct QuickCaptureView: View {
    @Environment(AppModel.self) private var model
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.captureDraft.ideaRequested ? "New Idea" : "Capture").font(.headline)
                Spacer()
                Button("Close", action: onDismiss)
            }
            CaptureComposer(shortcutFocus: true)
        }
        .padding(16)
        .onExitCommand(perform: onDismiss)
    }
}
