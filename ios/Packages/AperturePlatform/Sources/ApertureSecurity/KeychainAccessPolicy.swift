import Foundation
import Security

/// Which keychain accessibility class each stored secret uses.
///
/// This is small and easy to get wrong in a way that is invisible until the field:
/// background uploads run while the device is locked, so a refresh token stored as
/// `WhenUnlocked` becomes unreadable exactly when the background session needs it, and
/// every overnight sync fails with an authentication error that cannot be reproduced on a
/// desk where the phone is unlocked.
///
/// Every class here is a `ThisDeviceOnly` variant, so nothing travels in an encrypted
/// backup to another device.
public enum KeychainAccessPolicy: Sendable {
    /// Readable after the first unlock following a boot, including while locked.
    /// Required by anything the background sync path touches.
    case afterFirstUnlockThisDeviceOnly

    /// Readable only while the device is unlocked. For material that only a foreground
    /// user interaction needs.
    case whenUnlockedThisDeviceOnly

    public var secAttrAccessibleValue: CFString {
        switch self {
        case .afterFirstUnlockThisDeviceOnly:
            return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whenUnlockedThisDeviceOnly:
            return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}

/// Every secret this application stores, with its policy fixed at the type level so the
/// choice is made once, in one reviewable place, rather than at each call site.
public enum SecretKind: String, CaseIterable, Sendable {
    case refreshToken
    case accessToken
    case deviceIdentifier
    case hybridLogicalClockNodeID
    case biometricPolicyState

    public var accessPolicy: KeychainAccessPolicy {
        switch self {
        case .refreshToken, .accessToken, .deviceIdentifier, .hybridLogicalClockNodeID:
            // Background sync needs all four while the device is locked.
            return .afterFirstUnlockThisDeviceOnly
        case .biometricPolicyState:
            return .whenUnlockedThisDeviceOnly
        }
    }

    /// Keychain account name. Namespaced so a future app extension cannot collide.
    public var account: String {
        "com.aperture.secret.\(rawValue)"
    }
}
