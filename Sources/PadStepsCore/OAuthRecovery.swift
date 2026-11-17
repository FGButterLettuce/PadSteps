import Foundation

public enum OAuthRecovery {
    /// A server outage, quota response or malformed success is not revocation.
    public static func requiresReconnect(status: Int, error: String?) -> Bool {
        if status == 429 || status >= 500 { return false }
        if ["invalid_grant", "invalid_client", "unauthorized_client"].contains(error ?? "") { return true }
        return status == 401
    }
}
