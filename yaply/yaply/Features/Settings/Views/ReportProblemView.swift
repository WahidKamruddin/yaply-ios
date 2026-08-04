import SwiftUI

private enum BugStatus: String {
    case investigating, inProgress, fixReady

    var label: String {
        switch self {
        case .investigating: return "Investigating"
        case .inProgress: return "In progress"
        case .fixReady: return "Fix ready"
        }
    }

    var color: Color {
        switch self {
        case .investigating: return .yaplySecondary
        case .inProgress: return .yaplyAccent
        case .fixReady: return .yaplyMint
        }
    }
}

private let knownBugs: [(title: String, description: String, status: BugStatus)] = [
    ("New device can't read old messages", "Messages sent before a device was registered stay permanently unreadable on that device — expected under the current encryption design, key backup is planned.", .investigating),
    ("Media uploads are not encrypted", "Images, files, and stickers are stored as public URLs rather than end-to-end encrypted like text.", .investigating),
    ("No group re-keying on member changes", "Members removed from a group can still technically read messages sealed before they were removed; new members can't read history before they joined.", .investigating),
    ("Message edit UI missing", "The encryption contract for editing an already-sent message is defined, but there's no UI to edit messages yet.", .inProgress),
]

struct ReportProblemView: View {
    @State private var vm = ReportProblemViewModel()

    var body: some View {
        Group {
            if vm.sent {
                sentState
            } else {
                form
            }
        }
    }

    private var sentState: some View {
        VStack(spacing: 12) {
            Circle().fill(Color.yaplyMint.opacity(0.15)).frame(width: 48, height: 48)
                .overlay(Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.yaplyMint))
            VStack(spacing: 4) {
                Text("Report sent").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
                Text("Thanks — we'll take a look. Replies will go to your account email.")
                    .font(.caption)
                    .foregroundStyle(Color.yaplySecondary)
                    .multilineTextAlignment(.center)
            }
            Button("Send another") { vm.reset() }
                .font(.subheadline).fontWeight(.medium)
                .foregroundStyle(Color.yaplyAccent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(Color.yaplyTint).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "wrench").font(.system(size: 13)).foregroundStyle(Color.yaplySecondary))
                Text("Known issues being worked on").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.yaplyPrimary)
            }

            VStack(spacing: 8) {
                ForEach(knownBugs, id: \.title) { bug in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top) {
                            Text(bug.title).font(.subheadline).fontWeight(.medium).foregroundStyle(Color.yaplyPrimary)
                            Spacer()
                            Text(bug.status.label.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(bug.status.color)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(bug.status.color.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        Text(bug.description).font(.caption).foregroundStyle(Color.yaplySecondary)
                    }
                    .padding(14)
                    .background(Color.yaplyCard)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yaplyBorder))
                }
            }

            HStack(spacing: 10) {
                Circle().fill(Color.yaplyTint).frame(width: 32, height: 32)
                    .overlay(Image(systemName: "ladybug").font(.system(size: 14)).foregroundStyle(Color.yaplySecondary))
                Text("Found something else? Let us know below.")
                    .font(.subheadline)
                    .foregroundStyle(Color.yaplySecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Subject").font(.caption).foregroundStyle(Color.yaplySecondary)
                TextField("Short summary", text: $vm.subject)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.yaplyTint)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What happened?").font(.caption).foregroundStyle(Color.yaplySecondary)
                TextField("Steps to reproduce, what you expected, what you saw…", text: $vm.message, axis: .vertical)
                    .lineLimit(5...10)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color.yaplyTint)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
            }

            if let error = vm.error {
                Text(error).font(.subheadline).foregroundStyle(Color.yaplyDanger)
            }

            Button {
                Task { await vm.submit() }
            } label: {
                HStack(spacing: 6) {
                    if vm.isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                        Text("Send report")
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Color.yaplyAccent)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(vm.isSending || vm.subject.trimmingCharacters(in: .whitespaces).isEmpty || vm.message.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
