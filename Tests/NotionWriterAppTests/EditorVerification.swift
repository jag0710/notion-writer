import AppKit

extension AppVerification {
    @MainActor static func verifyEditorUndo(root: URL) async throws {
        let location = root.appendingPathComponent("editor-undo")
        let state = try state(root: location)
        let writer = WriterWindow(state: state)
        guard let panel = writer.window as? WriterPanel else { throw CheckFailure.failed("Writer panel missing") }
        panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }

        func shortcut(redo: Bool = false) throws {
            let modifiers: NSEvent.ModifierFlags = redo ? [.command, .shift] : .command
            let key = redo ? "Z" : "z"
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                              timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                              characters: key, charactersIgnoringModifiers: key,
                                              isARepeat: false, keyCode: 6) else {
                throw CheckFailure.failed("Unable to construct the history shortcut")
            }
            try require(panel.performKeyEquivalent(with: event), "Writer did not handle the history shortcut")
        }

        try require(panel.makeFirstResponder(writer.titleEditor), "Could not focus the title")
        writer.titleEditor.insertText("日本語🎷", replacementRange: NSRange(location: NSNotFound, length: 0))
        try require(state.draft.title == "日本語🎷", "Title editing did not reach the draft")
        await Task.yield()
        try shortcut()
        try require(writer.titleEditor.string.isEmpty && state.draft.title.isEmpty, "Title undo did not reach the draft")
        try shortcut(redo: true)
        try require(writer.titleEditor.string == "日本語🎷" && state.draft.title == "日本語🎷",
                    "Title redo did not reach the draft")

        writer.toggleBody()
        let body = writer.bodyEditor
        try require(panel.firstResponder === body, "Could not focus the body")
        try shortcut()
        try require(state.draft.title == "日本語🎷" && state.draft.body.isEmpty, "Body undo affected the title")

        body.insertText("本文", replacementRange: NSRange(location: NSNotFound, length: 0))
        await Task.yield()
        try shortcut()
        try require(body.string.isEmpty && state.draft.body.isEmpty, "Body typing was not undone")
        try shortcut(redo: true)
        try require(body.string == "本文" && state.draft.body == "本文", "Body typing was not recovered")
        body.breakUndoCoalescing()
        body.applyColor("gray_background", replacing: NSRange(location: body.string.utf16.count, length: 0))
        await Task.yield()
        let styled = state.draft.formattedBody
        try require(body.textStorage?.attribute(.bodyColor, at: 0, effectiveRange: nil) as? String == "gray_background",
                    "Body formatting did not apply")
        try shortcut()
        try require(body.string == "本文" && body.textStorage?.attribute(.bodyColor, at: 0, effectiveRange: nil) == nil &&
                    state.draft.formattedBody != styled, "Undo did not restore the old body formatting")
        try shortcut(redo: true)
        try require(body.string == "本文" && state.draft.formattedBody == styled, "Redo did not restore the formatted draft")
        try state.flush()
        let reloaded = try Self.state(root: location)
        try require(reloaded.draft == state.draft, "Undo and redo produced a draft that could not be reopened")

        try require(panel.makeFirstResponder(writer.titleEditor), "Could not return to the title")
        let title = writer.titleEditor
        title.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        let composing = title.string
        try shortcut()
        try require(title.hasMarkedText() && title.string == composing, "Undo interrupted Japanese IME composition")
        title.unmarkText()

        try state.clearDraft()
        writer.update()
        try require(title.undoManager?.canUndo == false && body.undoManager?.canUndo == false &&
                    title.undoManager?.canRedo == false && body.undoManager?.canRedo == false,
                    "Clearing the draft left an editor's undo or redo history")
        print("PASS: title and body shortcuts, separate history, formatting, IME protection and draft persistence")
    }
}
