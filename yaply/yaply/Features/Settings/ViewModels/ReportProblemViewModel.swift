import Foundation
import Supabase

@Observable
final class ReportProblemViewModel {
    var subject = ""
    var message = ""
    private(set) var isSending = false
    var error: String?
    private(set) var sent = false

    func submit() async {
        error = nil
        isSending = true
        defer { isSending = false }

        struct ReportBody: Encodable {
            let subject: String
            let message: String
        }

        do {
            try await supabase.functions.invoke(
                "report-problem",
                options: .init(body: ReportBody(
                    subject: subject.trimmingCharacters(in: .whitespaces),
                    message: message.trimmingCharacters(in: .whitespaces)
                ))
            )
            sent = true
            subject = ""
            message = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reset() {
        sent = false
    }
}
