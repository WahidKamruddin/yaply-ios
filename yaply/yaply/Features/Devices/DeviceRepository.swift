import Foundation
import Supabase
import PostgREST

// Mirrors src/features/pairing/api/devices.ts.
struct DeviceRepository {

    func fetchDevices(userId: UUID) async throws -> [ManagedDevice] {
        try await supabase
            .from("devices")
            .select("id, device_id, device_name, platform, key_fingerprint, last_active_at")
            .eq("user_id", value: userId.uuidString)
            .order("last_active_at", ascending: false)
            .execute()
            .value
    }

    func rename(userId: UUID, deviceId: Int, name: String) async throws {
        struct Rename: Encodable { let device_name: String? }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await supabase
            .from("devices")
            .update(Rename(device_name: trimmed.isEmpty ? nil : trimmed))
            .eq("user_id", value: userId.uuidString)
            .eq("device_id", value: String(deviceId))
            .execute()
    }

    // Revoking is three things, not one — see migration 00035. The RPC drops the
    // devices row AND kills the device's auth session; this side clears the local
    // keys when the revoked device is *this* one, so it can't re-register the
    // same identity on the next launch. A remote device does the same for itself,
    // either from the realtime delete (if running) or from the orphan check in
    // EncryptionRegistrar (if it was offline).
    //
    // Always go through the RPC — a plain DELETE on `devices` leaves the auth
    // session alive and the device simply re-registers.
    @discardableResult
    func revoke(userId: UUID, deviceId: Int) async throws -> Bool {
        struct Params: Encodable { let p_device_id: Int }
        let localDeviceId = try? KeyStore.loadDeviceId(forUser: userId)
        let isCurrentDevice = localDeviceId == deviceId

        try await supabase.rpc("revoke_device", params: Params(p_device_id: deviceId)).execute()

        if isCurrentDevice {
            KeyStore.clearAllKeys()
            try? await supabase.auth.signOut()
        }
        return isCurrentDevice
    }
}
