import AppKit

protocol TextDocumentDelegate: AnyObject {
    /// The text changed; `caret` is where the insertion point should land.
    func document(_ doc: TextDocument, didEditPlacingCaretAt caret: Int)
    /// Line count / size changed without an edit (background scan progress).
    func documentMetricsDidChange(_ doc: TextDocument)
}

/// Wraps a `PieceTable` with editing semantics: a single `replace` primitive,
/// undo/redo via `NSUndoManager`, a modified flag, and line indexing for the
/// background scan. The caret/selection itself lives in the view.
final class TextDocument {
    let pieceTable: PieceTable
    let file: MappedFile
    let index: LineIndex
    let undoManager = UndoManager()

    weak var delegate: TextDocumentDelegate?
    private(set) var isModified = false

    /// URL backing this document, or nil for an untitled buffer.
    var fileURL: URL?

    init(file: MappedFile, index: LineIndex, url: URL?) {
        self.file = file
        self.index = index
        self.fileURL = url
        self.pieceTable = PieceTable(original: file, index: index)

        // As the background scan discovers newlines, keep the (still unedited)
        // original piece's line count live, mirroring M0's growing document.
        index.onProgress = { [weak self] in
            guard let self, !self.isModified else { return }
            self.pieceTable.reindexOriginalPieces()
            self.delegate?.documentMetricsDidChange(self)
        }
    }

    static func empty() -> TextDocument {
        let file = MappedFile.empty()
        let index = LineIndex(file: file)
        index.buildSynchronously()
        return TextDocument(file: file, index: index, url: nil)
    }

    var byteCount: Int { pieceTable.byteCount }
    var lineCount: Int { pieceTable.lineCount }

    /// Replaces document bytes in `range` with `text`. Registers the inverse on
    /// the undo stack and notifies the delegate where the caret should go.
    func replace(_ range: Range<Int>, with text: String) {
        // Before the first edit, finalize the index so every original-piece line
        // count is authoritative even if the background scan hadn't finished.
        if !index.isFinished {
            index.buildSynchronously()
            pieceTable.reindexOriginalPieces()
        }
        let removed = pieceTable.delete(range)
        if !text.isEmpty { pieceTable.insert(text, at: range.lowerBound) }
        let insertedLen = text.utf8.count
        let newRange = range.lowerBound ..< (range.lowerBound + insertedLen)

        undoManager.registerUndo(withTarget: self) { doc in
            doc.replace(newRange, with: removed)
        }

        isModified = true
        delegate?.document(self, didEditPlacingCaretAt: newRange.upperBound)
    }

    func markSaved() { isModified = false }
}
