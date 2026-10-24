import Foundation

/// A small YAML reader for tracker front matter: scalars, quoted strings, block and flow lists,
/// `|`/`>` block text, and one level of nested maps (flattened as "parent.child").
/// Enough for the trackers Broski reads (a command center's findings, a register of items); anything fancier
/// is kept as raw text rather than guessed at.
public enum YAMLFrontMatter {
    public enum Value: Equatable {
        case string(String)
        case list([String])

        public var string: String? {
            switch self {
            case .string(let s): return s
            case .list(let items): return items.joined(separator: ", ")
            }
        }

        public var list: [String] {
            switch self {
            case .string(let s): return s.isEmpty ? [] : [s]
            case .list(let items): return items
            }
        }
    }

    /// Splits a markdown file into its front matter fields and body. No front matter: empty fields, whole text.
    public static func split(_ text: String) -> (fields: [String: Value], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return ([:], normalized) }
        let rest = normalized.dropFirst(4)
        // Empty front matter: checked first, or a "---" rule further down the body would be taken for the closing fence.
        if rest.hasPrefix("---\n") { return ([:], String(rest.dropFirst(4))) }
        let end: Range<Substring.Index>
        if let range = rest.range(of: "\n---\n") {
            end = range
        } else if rest.hasSuffix("\n---"), let range = rest.range(of: "\n---", options: .backwards) {
            end = range
        } else {
            return ([:], normalized)
        }
        let yaml = String(rest[rest.startIndex..<end.lowerBound])
        return (parse(yaml), String(rest[end.upperBound...]))
    }

    public static func parse(_ yaml: String) -> [String: Value] {
        var out: [String: Value] = [:]
        let lines = yaml.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.hasPrefix("#"),
                  indent(line) == 0, let colon = keyColon(line) else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if raw == "|" || raw == ">" || raw.hasPrefix("|") || raw.hasPrefix(">") {
                var block: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty || indent(lines[i]) > 0 {
                    block.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                let joined = raw.hasPrefix(">") ? block.joined(separator: " ") : block.joined(separator: "\n")
                out[key] = .string(joined.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if raw.isEmpty {
                // A block list or a nested map follows, indented.
                var items: [String] = []
                var nested: [(String, String)] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty || indent(lines[i]) > 0 {
                    let child = lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if child.isEmpty { continue }
                    if child.hasPrefix("- ") || child == "-" {
                        let item = String(child.dropFirst(child == "-" ? 1 : 2))
                        // "- key: value" list of maps: keep "key: value" text.
                        items.append(scalar(item))
                    } else if let c = keyColon(child) {
                        nested.append((String(child[..<c]).trimmingCharacters(in: .whitespaces),
                                       scalar(String(child[child.index(after: c)...]).trimmingCharacters(in: .whitespaces))))
                    } else if !items.isEmpty {
                        items[items.count - 1] += " " + child
                    }
                }
                if !items.isEmpty {
                    out[key] = .list(items)
                } else if !nested.isEmpty {
                    for (k, v) in nested { out["\(key).\(k)"] = .string(v) }
                    out[key] = .string(nested.map { "\($0.0): \($0.1)" }.joined(separator: "; "))
                } else {
                    out[key] = .string("")
                }
            } else if raw.hasPrefix("["), raw.hasSuffix("]") {
                let inner = raw.dropFirst().dropLast()
                out[key] = .list(splitFlow(String(inner)).map(scalar).filter { !$0.isEmpty })
            } else {
                out[key] = .string(scalar(raw))
            }
        }
        return out
    }

    static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    /// The colon that ends a key (not one inside a quoted value or a URL).
    static func keyColon(_ line: String) -> String.Index? {
        guard let first = line.first, first != "\"", first != "'", first != "-" else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let after = line.index(after: colon)
        guard after == line.endIndex || line[after] == " " else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        return !key.isEmpty && key.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) ? colon : nil
    }

    /// Unquotes a scalar: "json style", 'single', or plain (with a trailing # comment removed).
    static func scalar(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            if let data = s.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) { return decoded }
            return String(s.dropFirst().dropLast())
        }
        if s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if let hash = s.range(of: " #") { return String(s[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return s == "~" || s == "null" ? "" : s
    }

    static func splitFlow(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for ch in text {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current.trimmingCharacters(in: .whitespaces)) }
        return parts
    }
}
