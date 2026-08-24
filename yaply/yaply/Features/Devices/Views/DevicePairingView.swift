import SwiftUI

// The pairing flow. Both rendezvous options are always offered — "Show a code"
// and "Enter a code" — because a camera is never required: iOS is most often
// the sender to a desktop receiver that can't scan anything.
struct DevicePairingView: View {
    let userId: UUID
    let trustRole: PairingTrustRole
    var initialCode: String?
    var onFinished: () -> Void

    @State private var vm: DevicePairingViewModel
    @State private var typedCode = ""
    @State private var typedError: String?
    @State private var isScanning = false
    @Environment(\.dismiss) private var dismiss

    init(userId: UUID, trustRole: PairingTrustRole, initialCode: String? = nil, onFinished: @escaping () -> Void) {
        self.userId = userId
        self.trustRole = trustRole
        self.initialCode = initialCode
        self.onFinished = onFinished
        _vm = State(initialValue: DevicePairingViewModel(userId: userId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch vm.phase {
                case .idle:      rendezvousChooser
                case .waiting:   waitingState
                case .verifying: verifyingState
                case .transferring:
                    ProgressView("Transferring…")
                        .frame(maxWidth: .infinity)
                case .done:      doneState
                case .expired:   errorState("That code expired. Start over.")
                case .failed(let message): errorState(message)
                }
            }
            .padding(20)
        }
        .background(Color.yaplyBackground)
        .navigationTitle(trustRole == .sender ? "Send history" : "Get history")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let initialCode, let normalized = DevicePairingCrypto.normalizeCode(initialCode) {
                vm.start(role: trustRole, pairingCode: normalized)
            }
        }
        .onDisappear { vm.cancel() }
    }

    // MARK: — States

    private var rendezvousChooser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Either device can show the code — pick whichever is easier. A camera is never required.")
                .font(.caption)
                .foregroundStyle(Color.yaplySecondary)

            Button {
                vm.start(role: trustRole)
            } label: {
                Label("Show a code on this device", systemImage: "qrcode")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.yaplyAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            HStack {
                Rectangle().fill(Color.yaplyBorder).frame(height: 1)
                Text("or").font(.caption).foregroundStyle(Color.yaplySecondary)
                Rectangle().fill(Color.yaplyBorder).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the code shown on your other device")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.yaplySecondary)
                HStack(spacing: 8) {
                    TextField("XXXX-XXXX", text: $typedCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color.yaplyTint)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onSubmit(beginEntrant)
                    Button("Continue", action: beginEntrant)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Color.yaplyAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if let typedError {
                    Text(typedError).font(.caption).foregroundStyle(Color.yaplyDanger)
                }
                // Only offered where a camera actually exists — a device without
                // one should never see a control that leads nowhere.
                if QRScannerView.isAvailable {
                    Button {
                        isScanning = true
                    } label: {
                        Label("Scan the QR instead", systemImage: "qrcode.viewfinder")
                            .font(.caption)
                    }
                }
            }
        }
        .sheet(isPresented: $isScanning) {
            NavigationStack {
                QRScannerView(
                    onScan: { scanned in
                        isScanning = false
                        typedCode = scanned
                        beginEntrant()
                    },
                    onError: { message in
                        isScanning = false
                        typedError = message
                    }
                )
                .ignoresSafeArea()
                .navigationTitle("Scan code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isScanning = false }
                    }
                }
            }
        }
    }

    private var waitingState: some View {
        VStack(spacing: 16) {
            if let code = vm.code {
                PairingQRView(code: code)
                Text(DevicePairingCrypto.formatCode(code))
                    .font(.system(.title2, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(Color.yaplyPrimary)
                    .textSelection(.enabled)
                Text("Scan this, or type the code into your other device. Yaply will never ask you to share this code with anyone else.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.yaplySecondary)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the other device…")
                    .font(.caption).foregroundStyle(Color.yaplySecondary)
            }
            cancelButton
        }
        .frame(maxWidth: .infinity)
    }

    private var verifyingState: some View {
        VStack(spacing: 14) {
            Text("Check that this number matches on both screens. If it doesn't, cancel — someone else may be in the middle.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.yaplySecondary)
            Text(vm.sas ?? "------")
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(Color.yaplyPrimary)
            if vm.role == .sender {
                Button {
                    vm.confirmAndSend()
                } label: {
                    Label("Numbers match — send my keys", systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.yaplyAccent)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Text("Confirm on your other device to finish.")
                    .font(.caption).foregroundStyle(Color.yaplySecondary)
            }
            cancelButton
        }
        .frame(maxWidth: .infinity)
    }

    private var doneState: some View {
        VStack(spacing: 14) {
            Label(
                vm.role == .receiver
                    ? "Linked — \(vm.importedCount) key\(vm.importedCount == 1 ? "" : "s") imported."
                    : "Linked. The other device can read your history now.",
                systemImage: "checkmark.circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(Color.yaplyPrimary)

            Button("Done") {
                onFinished()
                dismiss()
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.yaplyAccent)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.yaplyDanger)
            Button("Start over") { vm.cancel() }
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity)
    }

    private var cancelButton: some View {
        Button("Cancel") { vm.cancel() }
            .font(.subheadline)
            .foregroundStyle(Color.yaplySecondary)
    }

    private func beginEntrant() {
        guard let normalized = DevicePairingCrypto.normalizeCode(typedCode) else {
            typedError = "That code doesn't look right — it should be 8 characters."
            return
        }
        typedError = nil
        vm.start(role: trustRole, pairingCode: normalized)
    }
}
