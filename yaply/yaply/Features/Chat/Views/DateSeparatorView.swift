import SwiftUI

struct DateSeparatorView: View {
    let date: Date

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateStyle = .long
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.yaplyBorder)
                .frame(height: 1)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.yaplySecondary)
                .fontWeight(.medium)
                .padding(.horizontal, 4)
            Rectangle()
                .fill(Color.yaplyBorder)
                .frame(height: 1)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }
}
