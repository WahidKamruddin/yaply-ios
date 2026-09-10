import SwiftUI

// Settings → Devices. Lists this user's registered devices with an inline
// rename and a confirmed sign-out, plus the two entry points into pairing.
struct DeviceSettingsView: View {
    let userId: UUID

    @State private var devices: [ManagedDevice] = []
    @State private var myFingerprint: String?
    @State private var renamingId: Int?
    @State private var renameDraft = ""
    @State private var pendingRevoke: ManagedDevice?
    @State private var isRevoking = false
    @State private var errorMessage: String?
    @State private var pairingRole: PairingTrustRole?

    private let repository = DeviceRepository()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            deviceList
            pairingSection
            footnote
        }
        .task { await load() }
        .navigationDestination(item: $pairingRole) { role in
            DevicePairingView(userId: userId, trustRole: role) {
                Task { await load() }
            }
        }
        .yaplyConfirm(
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            title: "Sign out \(pendingRevoke?.displayName ?? "this device")?",
            message: revokeMessage,
            icon: "iphone.slash",
            confirmLabel: "Sign out"
        ) {
            Task { await revoke() }
        }
    }

    private var revokeMessage: String {
        guard let pendingRevoke else { return "" }
        return isThisDevice(pendingRevoke)
            ? "This is the device you are using. You will be signed out immediately and will need to sign in and pair again to read your message history here."
            : "That device is signed out and stops receiving new messages. To use it again, you will need to sign in on it and pair it again to restore its message history."
    }

    // MARK: — Sections

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Your devices", icon: "laptopcomputer.and.iphone")

            if devices.isEmpty {
                Text("No devices registered yet.")
                    .font(.caption).foregroundStyle(Color.yaplySecondary)
            }

            ForEach(devices) { device in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if renamingId == device.deviceId {
                            TextField(device.displayName, text: $renameDraft)
                                .font(.subheadline)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await commitRename(device) } }
                        } else {
                            HStack(spacing: 6) {
                                Text(device.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.yaplyPrimary)
                                if isThisDevice(device) {
                                    Text("this device")
                                        .font(.caption2)
                                        .foregroundStyle(Color.yaplyMint)
                                }
                            }
                        }
                        Text(lastActiveLabel(device))
                            .font(.caption2)
                            .foregroundStyle(Color.yaplySecondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        renamingId = device.deviceId
                        renameDraft = device.deviceName ?? ""
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.yaplySecondary)

                    Button {
                        pendingRevoke = device
                    } label: {
                        Image(systemName: "trash").font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.yaplyDanger)
                }
                .padding(12)
                .background(Color.yaplyTint)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(Color.yaplyDanger)
            }
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Link a device", icon: "checkmark.shield")

            Text("Each device gets its own encryption key, so a new one can't read messages sent before it existed. Linking copies your existing key across so history opens up. Both devices have to be online at the same time.")
                .font(.caption)
                .foregroundStyle(Color.yaplySecondary)

            Button { pairingRole = .receiver } label: {
                pairingCard(
                    title: "Get history here",
                    subtitle: "This device is new. Pull the keys from a device that already has your messages."
                )
            }
            .buttonStyle(.plain)

            Button { pairingRole = .sender } label: {
                pairingCard(
                    title: "Send history from here",
                    subtitle: "This device already reads your messages. Hand its keys to another one."
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var footnote: some View {
        Label(
            "If you lose every linked device at once, past messages can't be recovered — nothing that could unlock them is stored on our servers.",
            systemImage: "iphone"
        )
        .font(.caption2)
        .foregroundStyle(Color.yaplySecondary)
    }

    private func pairingCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Color.yaplyPrimary)
            Text(subtitle).font(.caption).foregroundStyle(Color.yaplySecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.yaplyTint)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.yaplyTint)
                .frame(width: 32, height: 32)
                .overlay(Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color.yaplySecondary))
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.yaplyPrimary)
        }
    }

    // MARK: — Actions

    private func isThisDevice(_ device: ManagedDevice) -> Bool {
        guard let fp = device.keyFingerprint, let mine = myFingerprint else { return false }
        return fp == mine
    }

    private func lastActiveLabel(_ device: ManagedDevice) -> String {
        guard let date = device.lastActiveAt else { return "Last active unknown" }
        return "Last active \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func load() async {
        if let pub = try? KeyStore.loadIdentityPublicKey() {
            myFingerprint = EncryptionService.fingerprint(for: pub)
        }
        do {
            devices = try await repository.fetchDevices(userId: userId)
        } catch {
            errorMessage = "Could not load your devices."
        }
    }

    private func commitRename(_ device: ManagedDevice) async {
        let name = renameDraft
        renamingId = nil
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != (device.deviceName ?? "") else { return }
        do {
            try await repository.rename(userId: userId, deviceId: device.deviceId, name: name)
            await load()
        } catch {
            errorMessage = "Could not rename that device."
        }
    }

    private func revoke() async {
        guard let device = pendingRevoke else { return }
        isRevoking = true
        errorMessage = nil
        do {
            // Revoking the device you're holding signs you out here and now, so
            // there is no list left to refresh.
            let wasCurrent = try await repository.revoke(userId: userId, deviceId: device.deviceId)
            pendingRevoke = nil
            if !wasCurrent { await load() }
        } catch {
            errorMessage = "Could not sign that device out. Try again."
        }
        isRevoking = false
    }
}
