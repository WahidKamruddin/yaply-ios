import Foundation

/// Swift port of `packages/shared/src/money.ts`. Form math is done in integer
/// cents; the server decides and stores every share, so the equal-split preview
/// here is display only — but it applies the same rule so the preview matches.
nonisolated enum BudgetMoney {
    static let currencies = ["USD", "EUR", "GBP", "CAD"]
    static let categories = ["food", "transport", "entertainment", "utilities", "rent", "health", "shopping", "other"]

    /// Mirrors the server's `amount < 10_000_000_000` bound on numeric(12,2).
    private static let maxCents = 999_999_999_999

    /// "12", "12.5", "1,234.56", ".5" → cents. nil for zero, negatives, junk and
    /// more than two decimals — rejecting beats silently rounding someone's money.
    static func parseCents(_ input: String) -> Int? {
        let s = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard s.range(of: #"^(\d+(\.\d{1,2})?|\.\d{1,2})$"#, options: .regularExpression) != nil else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let whole = Int(parts[0].isEmpty ? "0" : String(parts[0])) ?? -1
        let fracText = parts.count > 1 ? String(parts[1]) : ""
        let frac = Int(fracText.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        guard whole >= 0, whole <= maxCents / 100 else { return nil }
        let cents = whole * 100 + frac
        return cents > 0 && cents <= maxCents ? cents : nil
    }

    static func cents(_ amount: Decimal) -> Int {
        var scaled = amount * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    static func decimal(cents: Int) -> Decimal {
        Decimal(cents) / 100
    }

    static func inputString(cents: Int) -> String {
        String(format: "%d.%02d", cents / 100, cents % 100)
    }

    static func format(_ amount: Decimal, currency: String) -> String {
        amount.formatted(.currency(code: currency.trimmingCharacters(in: .whitespaces).uppercased()))
    }

    static func format(cents: Int, currency: String) -> String {
        format(decimal(cents: cents), currency: currency)
    }

    /// floor(total / n) cents each; leftover cents +1 each in ascending id order.
    /// Postgres orders uuid by bytes = lowercase hex string order.
    static func previewEqualSplit(totalCents: Int, userIds: [UUID]) -> [UUID: Int] {
        let ids = Array(Set(userIds)).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
        guard !ids.isEmpty else { return [:] }
        let base = totalCents / ids.count
        let rem = totalCents % ids.count
        var out: [UUID: Int] = [:]
        for (i, id) in ids.enumerated() { out[id] = base + (i < rem ? 1 : 0) }
        return out
    }
}
