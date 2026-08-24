import AVFoundation
import SwiftUI

// Camera QR scanner. Only ever presented when a camera is actually usable —
// pairing must never be gated behind one, since iOS is most often the *sender*
// to a desktop receiver that has no camera at all.
//
// Decoded content is untrusted input: only the fragment parameter is pulled out
// of it, and the URL is never opened or otherwise acted upon.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    static var isAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    static func extractCode(_ raw: String) -> String? {
        if let match = raw.range(of: "[#?&]c=([0-9A-Za-z]+)", options: .regularExpression) {
            return String(raw[match].dropFirst(3))
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let parent: QRScannerView
        private var handled = false

        init(_ parent: QRScannerView) { self.parent = parent }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard
                !handled,
                let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                object.type == .qr,
                let value = object.stringValue,
                let code = QRScannerView.extractCode(value)
            else { return }
            handled = true
            DispatchQueue.main.async { self.parent.onScan(code) }
        }

        func failed(_ message: String) {
            DispatchQueue.main.async { self.parent.onError(message) }
        }
    }

    final class ScannerController: UIViewController {
        weak var delegate: Coordinator?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            configure()
        }

        private func configure() {
            guard
                let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                delegate?.failed("Could not access the camera. Enter the code by hand instead.")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                delegate?.failed("Could not start the scanner. Enter the code by hand instead.")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(delegate, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.layer.bounds
            view.layer.addSublayer(layer)
            previewLayer = layer

            // startRunning blocks; keep it off the main thread.
            Task.detached { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.layer.bounds
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            let session = self.session
            Task.detached { session.stopRunning() }
        }
    }
}
