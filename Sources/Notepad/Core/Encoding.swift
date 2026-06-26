import Foundation

/// What we detected about a file's byte format, used for the status bar, for
/// skipping a leading BOM in the editable content, and for choosing which line
/// ending to insert when the user presses Return.
struct DetectedFormat {
    var encodingLabel: String      // status-bar text, e.g. "UTF-8"
    var bomBytes: [UInt8]          // re-emitted on save
    var contentStart: Int          // first editable byte (past any BOM)
    var newline: String            // inserted on Return
    var lineEndingLabel: String    // status-bar text, e.g. "Windows (CRLF)"

    /// Default for new, empty documents — UTF-8 with CRLF, like Windows Notepad.
    static let `default` = DetectedFormat(
        encodingLabel: "UTF-8", bomBytes: [], contentStart: 0,
        newline: "\r\n", lineEndingLabel: "Windows (CRLF)")
}

func detectFormat(_ file: MappedFile) -> DetectedFormat {
    let n = file.count
    guard n > 0 else { return .default }

    var encodingLabel = "UTF-8"
    var bom: [UInt8] = []
    var contentStart = 0

    if n >= 3, file.byte(at: 0) == 0xEF, file.byte(at: 1) == 0xBB, file.byte(at: 2) == 0xBF {
        encodingLabel = "UTF-8 with BOM"; bom = [0xEF, 0xBB, 0xBF]; contentStart = 3
    } else if n >= 2, file.byte(at: 0) == 0xFF, file.byte(at: 1) == 0xFE {
        encodingLabel = "UTF-16 LE"; bom = [0xFF, 0xFE]; contentStart = 2
    } else if n >= 2, file.byte(at: 0) == 0xFE, file.byte(at: 1) == 0xFF {
        encodingLabel = "UTF-16 BE"; bom = [0xFE, 0xFF]; contentStart = 2
    }

    // Decide the line ending from the first one in a 64 KB sample.
    var newline = "\r\n"
    var label = "Windows (CRLF)"
    let sampleEnd = min(n, contentStart + (1 << 16))
    var i = contentStart
    while i < sampleEnd {
        let b = file.byte(at: i)
        if b == 0x0A {
            newline = "\n"; label = "Unix (LF)"; break
        }
        if b == 0x0D {
            if i + 1 < n, file.byte(at: i + 1) == 0x0A {
                newline = "\r\n"; label = "Windows (CRLF)"
            } else {
                newline = "\r"; label = "Macintosh (CR)"
            }
            break
        }
        i += 1
    }

    return DetectedFormat(encodingLabel: encodingLabel, bomBytes: bom,
                          contentStart: contentStart, newline: newline, lineEndingLabel: label)
}
