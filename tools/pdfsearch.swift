// pdfsearch.swift — find a phrase in the Resolve manual and print page context.
// usage: swift tools/pdfsearch.swift "<phrase>" [max-results]
import Foundation
import PDFKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: pdfsearch <phrase> [max-pages]")
    exit(1)
}
let phrase = args[1]
let maxResults = args.count > 2 ? Int(args[2]) ?? 5 : 5

guard let doc = PDFDocument(url: URL(fileURLWithPath: "/Applications/DaVinci Resolve/DaVinci Resolve Manual.pdf")) else {
    print("could not open manual")
    exit(1)
}

let matches = doc.findString(phrase, withOptions: [.caseInsensitive])
print("total matches for \"\(phrase)\": \(matches.count)")

var shown = 0
var seenPages = Set<Int>()
outer: for selection in matches {
    for page in selection.pages {
        let idx = doc.index(for: page)
        guard !seenPages.contains(idx) else { continue }
        seenPages.insert(idx)
        guard let text = page.string else { continue }
        var searchRange = text.startIndex..<text.endIndex
        while let r = text.range(of: phrase, options: .caseInsensitive, range: searchRange) {
            let start = text.index(r.lowerBound, offsetBy: -400, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: 700, limitedBy: text.endIndex) ?? text.endIndex
            print("\n===== page \(idx + 1) =====")
            print(text[start..<end].replacingOccurrences(of: "\n", with: " "))
            shown += 1
            if shown >= maxResults { break outer }
            searchRange = r.upperBound..<text.endIndex
        }
    }
}
