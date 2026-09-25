import Foundation

/// Friendly model names — a port of the desktop app's `modelDisplayParts`
/// (`apps/desktop/src/lib/model-status-label.ts`) so both apps label a model the same way:
/// `claude/claude-opus-5-5` → "Opus 5.5", `openai/gpt-5.5` → "GPT-5.5",
/// `Qwen3.6-27B-UD-Q4_K_XL` → "Qwen3.6 27B" · "Q4". Display only: every selection, comparison
/// and `config.set` still uses the raw id.
public enum ModelDisplayName {
  public struct Parts: Equatable, Sendable {
    public let name: String
    /// Grayed variant beside the name ("Fast", "1M", "Q4"); empty when none.
    public let tag: String
  }

  /// One-line label: name, plus " · tag" when there is a variant tag.
  public static func label(_ model: String) -> String {
    let parts = parts(model)
    return parts.tag.isEmpty ? parts.name : "\(parts.name) · \(parts.tag)"
  }

  public static func parts(_ model: String) -> Parts {
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    var base = trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
    var tag = ""

    // Local GGUF quant suffix → quiet tag, never part of the name.
    if let quant = firstMatch(#"-(?:UD-)?(Q\d(?:_[A-Z0-9]+)*|IQ\d(?:_[A-Z0-9]+)*|F16|BF16)$"#, in: base) {
      tag = String(quant.group.split(separator: "_").first ?? Substring(quant.group)).uppercased()
      base = String(base.prefix(base.count - quant.whole.count))
      base = replacing(#"-(?:Instruct|Chat)(?:-\d{4})?$"#, in: base, with: "")
    }

    if tag.isEmpty {
      for (pattern, label) in [("-fast$", "Fast"), ("-thinking$", "Thinking"),
                               ("-preview$", "Preview"), ("-latest$", "Latest")]
      where firstMatch(pattern, in: base) != nil {
        tag = label
        base = replacing(pattern, in: base, with: "")
        break
      }
    }

    // Anthropic `[1m]` context-window route suffix → tag, not raw brackets.
    if let window = firstMatch(#"\[(\d+[mk])\]$"#, in: base) {
      let size = window.group.uppercased()
      tag = tag.isEmpty ? size : "\(tag) \(size)"
      base = String(base.prefix(base.count - window.whole.count))
    }

    // Trailing date pin (`…-20251101`) is snapshot noise.
    base = replacing(#"-\d{8}$"#, in: base, with: "")

    let pretty = prettify(base)
    let name = !pretty.isEmpty ? pretty : (!trimmed.isEmpty ? trimmed : "No model")
    return Parts(name: name, tag: tag)
  }

  private static func prettify(_ base: String) -> String {
    if firstMatch("^deepseek-flash$", in: base) != nil { return "DeepSeek V4.1 Flash" }
    if firstMatch("^claude-", in: base) != nil {
      // `opus-5-5` → "Opus 5.5": hyphen between digits is a version dot.
      var s = replacing("^claude-", in: base, with: "")
      s = replacing(#"(\d)-(?=\d)"#, in: s, with: "$1.")
      return titleCase(s.replacingOccurrences(of: "-", with: " "))
    }
    if firstMatch("^gpt-", in: base) != nil { return replacing("^gpt-", in: base, with: "GPT-") }
    if firstMatch("^gemini-", in: base) != nil {
      return replacing("^gemini-", in: base, with: "Gemini ").replacingOccurrences(of: "-", with: " ")
    }
    return titleCase(base.replacingOccurrences(of: "-", with: " "))
  }

  /// JS `\b\w` → uppercase: capitalize the first word character after a non-word boundary,
  /// leaving the rest untouched ("qwen3.6 27B" → "Qwen3.6 27B", not "Qwen3.6 27b").
  private static func titleCase(_ text: String) -> String {
    var out = ""
    var previousIsWord = false
    for ch in text {
      let isWord = ch.isLetter || ch.isNumber || ch == "_"
      out.append(isWord && !previousIsWord ? Character(ch.uppercased()) : ch)
      previousIsWord = isWord
    }
    return out.trimmingCharacters(in: .whitespaces)
  }

  private static func firstMatch(_ pattern: String, in text: String) -> (whole: String, group: String)? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let whole = Range(match.range, in: text) else { return nil }
    let group = match.numberOfRanges > 1 ? Range(match.range(at: 1), in: text).map { String(text[$0]) } : nil
    return (String(text[whole]), group ?? String(text[whole]))
  }

  private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return text }
    return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                          withTemplate: template)
  }
}
