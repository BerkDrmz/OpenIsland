import AppKit
import SwiftUI

/// Sabit genişlikli dakika girişi. Taslak yazılırken sayaç değişmez; Enter veya odak çıkışı uygular.
struct FocusDurationField: NSViewRepresentable {
    @Binding var value: Int
    let label: String
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> DurationTextField {
        let field = DurationTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        field.textColor = .white
        field.alignment = .right
        field.lineBreakMode = .byClipping
        field.usesSingleLineMode = true
        field.isEditable = true
        field.isSelectable = true
        field.setAccessibilityLabel(label)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: DurationTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        if !isEnabled, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        if field.currentEditor() == nil { field.stringValue = String(value) }
        field.setAccessibilityLabel(label)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusDurationField
        init(_ parent: FocusDurationField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let digits = String(field.stringValue.filter { $0 >= "0" && $0 <= "9" }.prefix(3))
            if digits != field.stringValue {
                field.stringValue = digits
                field.currentEditor()?.string = digits
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            commit(field)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commit(field)
                field.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                field.stringValue = String(parent.value)
                textView.string = field.stringValue
                field.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }

        private func commit(_ field: NSTextField) {
            if parent.isEnabled, let minutes = Int(field.stringValue) {
                parent.value = min(max(minutes, 1), 180)
            }
            field.stringValue = String(parent.value)
            field.currentEditor()?.string = field.stringValue
        }
    }
}

/// Yalnızca bu alan tıklanınca nonactivating panel klavye odağı alır; pencere konumuna dokunulmaz.
final class DurationTextField: NSTextField {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { window?.makeKey() }
        super.mouseDown(with: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        window?.makeKey()
        selectText(nil)
        return true
    }
}
