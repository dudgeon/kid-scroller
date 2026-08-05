import Foundation

/// Display formatting and parsing for ages on the axis.
///
/// Port of the prototype's `fmtAge` plus the age-input parser behind the current-age pill (R12).
public enum AgeFormatter {
    /// `"2y 1m"` / `"9m"`. Mirrors the prototype: whole years, months rounded to nearest.
    ///
    /// Rounding can carry to 12 (e.g. 23.6mo → 1y 12m); we normalize that to `2y 0m`.
    public static func short(months: Double) -> String {
        let clamped = max(0, months)
        var years = Int(clamped / 12)
        var remainder = Int((clamped - Double(years) * 12).rounded())
        if remainder == 12 {
            years += 1
            remainder = 0
        }
        return years > 0 ? "\(years)y \(remainder)m" : "\(remainder)m"
    }

    /// Year-tick label for the age rail (D5: year ticks only).
    public static func yearTick(months: Double) -> String {
        let years = Int((months / 12).rounded())
        return years == 0 ? "0" : "\(years)y"
    }

    /// Parses the age-input field. Accepts bare months (`"15"`, `"15mo"`, `"15 m"`),
    /// years (`"2.5y"`, `"2.5 years"`), and combined (`"2y 6m"`). Returns months, or
    /// `nil` if unparseable. Never returns a negative value.
    public static func parse(_ input: String) -> Double? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }

        // Combined "2y 6m" / "2y6m" — check first so the year branch doesn't swallow it.
        if let combined = firstMatch(in: s, pattern: #"^([0-9]*\.?[0-9]+)\s*y(?:ears?|r)?\s*([0-9]*\.?[0-9]+)\s*m"#),
           combined.count == 2,
           let y = Double(combined[0]), let m = Double(combined[1]) {
            return max(0, y * 12 + m)
        }
        // Years: "2.5y", "2 years", "3 yr"
        if let years = firstMatch(in: s, pattern: #"^([0-9]*\.?[0-9]+)\s*y(?:ears?|r)?$"#),
           let y = Double(years[0]) {
            return max(0, y * 12)
        }
        // Months: "15", "15m", "15mo", "15 months"
        if let months = firstMatch(in: s, pattern: #"^([0-9]*\.?[0-9]+)\s*(?:m(?:o|onths?)?)?$"#),
           let m = Double(months[0]) {
            return max(0, m)
        }
        return nil
    }

    /// Returns the capture groups of the first match, or `nil`.
    private static func firstMatch(in s: String, pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
        else { return nil }
        var groups: [String] = []
        for i in 1..<match.numberOfRanges {
            guard let r = Range(match.range(at: i), in: s) else { return nil }
            groups.append(String(s[r]))
        }
        return groups
    }
}
