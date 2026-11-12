import AppKit

// Uses a private named pasteboard so the user's clipboard is never touched.
func check(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}

@main
enum PasteboardRestoreChecks {
    static func main() async {
        let board = NSPasteboard(name: NSPasteboard.Name("acento-checks-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let rich = NSPasteboard.PasteboardType("public.rtf")

        func copyOriginal() {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString("original", forType: .string)
            item.setData(Data("{\\rtf1 original}".utf8), forType: rich)
            board.writeObjects([item])
        }

        // Restores every type after a successful paste and marks the dictation as transient.
        copyOriginal()
        guard let snapshot = PasteboardRestore.prepare("dictado", on: board) else { fatalError("prepare failed") }
        check(board.string(forType: .string) == "dictado", "dictation should be on the pasteboard")
        check(board.types?.contains(PasteboardRestore.transientTypes[0]) == true, "dictation should be transient")
        PasteboardRestore.restore(snapshot, after: 0.05, on: board)
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(board.string(forType: .string) == "original", "original text should be restored")
        check(board.data(forType: rich) == Data("{\\rtf1 original}".utf8), "rich data should be restored")

        // Something copied before the restore fires wins.
        copyOriginal()
        let second = PasteboardRestore.prepare("dictado", on: board)!
        PasteboardRestore.restore(second, after: 0.05, on: board)
        board.clearContents()
        board.setString("copied later", forType: .string)
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(board.string(forType: .string) == "copied later", "newer copy must not be overwritten")

        // Back-to-back dictations restore the user's content, not the first dictation.
        copyOriginal()
        let first = PasteboardRestore.prepare("uno", on: board)!
        PasteboardRestore.restore(first, after: 0.5, on: board)
        let next = PasteboardRestore.prepare("dos", on: board)!
        PasteboardRestore.restore(next, after: 0.05, on: board)
        try? await Task.sleep(nanoseconds: 700_000_000)
        check(board.string(forType: .string) == "original", "consecutive dictations should keep the original")

        // An empty pasteboard is restored as empty.
        board.clearContents()
        let empty = PasteboardRestore.prepare("dictado", on: board)!
        PasteboardRestore.restore(empty, after: 0.05, on: board)
        try? await Task.sleep(nanoseconds: 200_000_000)
        check(board.pasteboardItems?.isEmpty ?? true, "empty pasteboard should stay empty")

        print("Passed pasteboard restore checks.")
    }
}
