import Foundation

struct LyricLine: Equatable, Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

/// Parses standard LRC text (`[mm:ss.xx]lyric text` per line) into LyricLine[].
enum LRCParser {
    static func parse(_ lrc: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{1,2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var lines: [LyricLine] = []
        for rawLine in lrc.components(separatedBy: .newlines) {
            let nsLine = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: nsLine.length))
            guard !matches.isEmpty else { continue }

            let lastMatch = matches[matches.count - 1]
            let text = nsLine.substring(from: lastMatch.range.location + lastMatch.range.length)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            for match in matches {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                var fraction: Double = 0
                if match.range(at: 3).location != NSNotFound {
                    let fracStr = nsLine.substring(with: match.range(at: 3))
                    fraction = (Double(fracStr) ?? 0) / pow(10, Double(fracStr.count))
                }
                let time = minutes * 60 + seconds + fraction
                lines.append(LyricLine(time: time, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
