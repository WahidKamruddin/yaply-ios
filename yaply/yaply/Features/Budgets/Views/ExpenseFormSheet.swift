import SwiftUI

nonisolated struct ExpenseFormInput: Sendable {
    let description: String
    let amountCents: Int
    let category: String
    let paidBy: UUID
    /// "equal" | "exact"
    let splitMode: String
    let participants: [UUID]
    let exactCents: [UUID: Int]?
    let spentOn: String
}

/// Add / edit an expense. Same fields and rules as web's ExpenseDialog: equal
/// split with a per-person preview, or exact amounts that must add up to the
/// total before Save enables. The server recomputes and stores the shares.
struct ExpenseFormSheet: View {
    let budget: YaplyBudget
    let members: [MemberSummary]
    let currentUserId: UUID
    let names: BudgetNames
    let expense: YaplyExpense?
    /// Returns an error message to show inline, or nil on success.
    let onSave: (ExpenseFormInput) async -> String?

    @Environment(\.yaplyPopupDismiss) private var dismiss

    @State private var description: String
    @State private var amount: String
    @State private var category: String
    @State private var paidBy: UUID
    @State private var spentOn: Date
    @State private var splitMode: String
    @State private var participants: Set<UUID>
    @State private var exact: [UUID: String]
    @State private var isSaving = false
    @State private var saveError: String?

    init(budget: YaplyBudget, members: [MemberSummary], currentUserId: UUID, names: BudgetNames, expense: YaplyExpense?, onSave: @escaping (ExpenseFormInput) async -> String?) {
        self.budget = budget
        self.members = members
        self.currentUserId = currentUserId
        self.names = names
        self.expense = expense
        self.onSave = onSave
        _description = State(initialValue: expense?.description ?? "")
        _amount = State(initialValue: expense.map { BudgetMoney.inputString(cents: BudgetMoney.cents($0.amount)) } ?? "")
        _category = State(initialValue: expense?.category ?? "other")
        _paidBy = State(initialValue: expense?.paidBy ?? currentUserId)
        _spentOn = State(initialValue: expense.flatMap { BudgetDate.date(from: $0.spentOn) } ?? Date())
        _splitMode = State(initialValue: expense?.splitMode ?? "equal")
        _participants = State(initialValue: Set(expense?.shares.map(\.userId) ?? members.map(\.userId)))
        _exact = State(initialValue: expense?.splitMode == "exact"
            ? Dictionary(uniqueKeysWithValues: (expense?.shares ?? []).map { ($0.userId, BudgetMoney.inputString(cents: BudgetMoney.cents($0.amount))) })
            : [:])
    }

    /// Current members, plus anyone on this expense who has since left (the
    /// server rejects keeping them, and says so).
    private var people: [UUID] {
        var ids = members.map(\.userId)
        for id in [expense?.paidBy].compactMap({ $0 }) + (expense?.shares.map(\.userId) ?? []) where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    private var amountCents: Int? { BudgetMoney.parseCents(amount) }

    private var exactCents: (values: [UUID: Int], invalid: Bool) {
        var out: [UUID: Int] = [:]
        var invalid = false
        for (id, text) in exact {
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "0" { continue }
            if let c = BudgetMoney.parseCents(t) { out[id] = c } else { invalid = true }
        }
        return (out, invalid)
    }

    private var remaining: Int { (amountCents ?? 0) - exactCents.values.values.reduce(0, +) }

    private var canSave: Bool {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let cents = amountCents, !isSaving else { return false }
        if splitMode == "equal" {
            return !participants.isEmpty && cents >= participants.count
        }
        let e = exactCents
        return !e.invalid && !e.values.isEmpty && remaining == 0
    }

    var body: some View {
        YaplySheetScaffold(
            title: expense == nil ? "Add expense" : "Edit expense",
            primaryLabel: isSaving ? "Saving…" : (expense == nil ? "Add" : "Save"),
            primaryEnabled: canSave,
            primaryAction: save
        ) {
            VStack(spacing: 16) {
                YaplyLabeledField(label: "Description") {
                    TextField("What was it for?", text: $description)
                        .yaplyInputStyle()
                }
                HStack(spacing: 12) {
                    YaplyLabeledField(label: "Amount (\(budget.currency))") {
                        TextField("0.00", text: $amount)
                            .keyboardType(.decimalPad)
                            .yaplyInputStyle()
                    }
                    YaplyLabeledField(label: "Category") {
                        Picker("Category", selection: $category) {
                            ForEach(BudgetMoney.categories, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.yaplyPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .background(Color.yaplyTint)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                HStack(spacing: 12) {
                    YaplyLabeledField(label: "Paid by") {
                        Picker("Paid by", selection: $paidBy) {
                            ForEach(people, id: \.self) { Text(names.name($0)).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(Color.yaplyPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .background(Color.yaplyTint)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    YaplyLabeledField(label: "Date") {
                        DatePicker("Date", selection: $spentOn, in: ...Date(), displayedComponents: .date)
                            .labelsHidden()
                    }
                }

                YaplyLabeledField(label: "Split") {
                    VStack(spacing: 10) {
                        Picker("Split", selection: $splitMode) {
                            Text("Equally").tag("equal")
                            Text("Exact amounts").tag("exact")
                        }
                        .pickerStyle(.segmented)
                        splitRows
                        splitFooter
                    }
                }

                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(Color.yaplyDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var splitRows: some View {
        let preview = BudgetMoney.previewEqualSplit(totalCents: amountCents ?? 0, userIds: Array(participants))
        VStack(spacing: 0) {
            ForEach(people, id: \.self) { id in
                HStack {
                    if splitMode == "equal" {
                        Button {
                            if participants.contains(id) { participants.remove(id) } else { participants.insert(id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: participants.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(participants.contains(id) ? Color.yaplyAccent : Color.yaplySecondary)
                                Text(names.name(id)).foregroundStyle(Color.yaplyPrimary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Text(amountCents != nil && participants.contains(id)
                             ? BudgetMoney.format(cents: preview[id] ?? 0, currency: budget.currency)
                             : "—")
                            .foregroundStyle(Color.yaplySecondary)
                    } else {
                        Text(names.name(id)).foregroundStyle(Color.yaplyPrimary)
                        Spacer()
                        TextField("0.00", text: Binding(
                            get: { exact[id] ?? "" },
                            set: { exact[id] = $0 }
                        ))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 96)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.yaplyTint)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .font(.system(size: 15))
                .padding(.vertical, 8)
                if id != people.last { Divider() }
            }
        }
        .padding(.horizontal, 12)
        .background(Color.yaplyCard)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.yaplyBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var splitFooter: some View {
        if splitMode == "equal" && participants.isEmpty {
            footer("Pick at least one person.", color: .yaplyDanger)
        } else if splitMode == "exact", amountCents != nil {
            if remaining == 0 {
                footer("All assigned", color: .yaplyOnline)
            } else if remaining > 0 {
                footer("\(BudgetMoney.format(cents: remaining, currency: budget.currency)) left to assign", color: .yaplyDanger)
            } else {
                footer("\(BudgetMoney.format(cents: -remaining, currency: budget.currency)) over the total", color: .yaplyDanger)
            }
        }
    }

    private func footer(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard canSave, let cents = amountCents else { return }
        let input = ExpenseFormInput(
            description: description,
            amountCents: cents,
            category: category,
            paidBy: paidBy,
            splitMode: splitMode,
            participants: Array(participants),
            exactCents: splitMode == "exact" ? exactCents.values : nil,
            spentOn: BudgetDate.string(from: spentOn)
        )
        isSaving = true
        saveError = nil
        Task {
            let error = await onSave(input)
            isSaving = false
            if let error { saveError = error } else { dismiss() }
        }
    }
}

struct SettleUpSheet: View {
    let budget: YaplyBudget
    let debt: BudgetDebt
    let names: BudgetNames
    /// Returns an error message to show inline, or nil on success.
    let onRecord: (Int) async -> String?

    @Environment(\.yaplyPopupDismiss) private var dismiss
    @State private var amount: String
    @State private var isSaving = false
    @State private var saveError: String?

    init(budget: YaplyBudget, debt: BudgetDebt, names: BudgetNames, onRecord: @escaping (Int) async -> String?) {
        self.budget = budget
        self.debt = debt
        self.names = names
        self.onRecord = onRecord
        _amount = State(initialValue: BudgetMoney.inputString(cents: BudgetMoney.cents(debt.amount)))
    }

    private var cents: Int? { BudgetMoney.parseCents(amount) }

    var body: some View {
        YaplySheetScaffold(
            title: "Record a payment",
            subtitle: "\(names.name(debt.fromUser)) paid \(names.name(debt.toUser, object: true))",
            primaryLabel: isSaving ? "Saving…" : "Record",
            primaryEnabled: cents != nil && !isSaving,
            primaryAction: record
        ) {
            VStack(spacing: 12) {
                YaplyLabeledField(label: "Amount (\(budget.currency))") {
                    TextField("0.00", text: $amount)
                        .keyboardType(.decimalPad)
                        .yaplyInputStyle()
                }
                Text("Records a payment made outside Yaply. It doesn't move any money.")
                    .font(.footnote)
                    .foregroundStyle(Color.yaplySecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let saveError {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(Color.yaplyDanger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func record() {
        guard let cents else { return }
        isSaving = true
        saveError = nil
        Task {
            let error = await onRecord(cents)
            isSaving = false
            if let error { saveError = error } else { dismiss() }
        }
    }
}
