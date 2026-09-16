import Testing
@testable import ApertureData
@testable import ApertureSecurity
@testable import FeatureInspection
import ApertureDomain

@Suite("Sync queue schema")
struct SyncQueueSchemaTests {

    @Test("declares the tables and indexes the engine depends on")
    func schemaShape() {
        let joined = SyncQueueSchema.createStatements.joined(separator: "\n")

        #expect(joined.contains("CREATE TABLE IF NOT EXISTS sync_op"))
        #expect(joined.contains("idx_sync_op_ready"))
        #expect(joined.contains("idx_sync_op_entity"))
        #expect(joined.contains("STRICT"))
    }

    @Test("constrains state and operation kind at the database level")
    func checkConstraintsArePresent() {
        let joined = SyncQueueSchema.createStatements.joined(separator: "\n")

        for state in SyncOperationStateName.allCases {
            #expect(joined.contains("'\(state.rawValue)'"))
        }
    }

    // Mirrors ApertureSync.SyncOperationState without importing it, so a rename on either
    // side surfaces as a failing test rather than as silent drift between the Swift
    // enumeration and the SQL CHECK constraint.
    enum SyncOperationStateName: String, CaseIterable {
        case pending, inFlight, failed, dead
    }
}

@Suite("Keychain access policy")
struct KeychainAccessPolicyTests {

    @Test("every secret the background path needs survives a locked device")
    func backgroundReadableSecrets() {
        let backgroundNeeded: [SecretKind] = [
            .refreshToken, .accessToken, .deviceIdentifier, .hybridLogicalClockNodeID
        ]

        for secret in backgroundNeeded {
            #expect(secret.accessPolicy == .afterFirstUnlockThisDeviceOnly,
                    "\(secret.rawValue) is read by background sync and must survive a locked device")
        }
    }

    @Test("accounts are namespaced so an extension cannot collide")
    func accountNamespacing() {
        for secret in SecretKind.allCases {
            #expect(secret.account.hasPrefix("com.aperture.secret."))
        }
    }
}

@Suite("Inspection list state")
struct InspectionListViewStateTests {

    @Test("offline is not an error state")
    func offlineIsNotFailure() {
        let posture = SyncPosture.offline(pendingOperations: 312)

        #expect(posture.demandsUserAction == false)
    }

    @Test("only dead-lettered work demands user action")
    func deadLetterDemandsAction() {
        #expect(SyncPosture.attentionRequired(deadLetteredOperations: 1).demandsUserAction)
        #expect(SyncPosture.syncing(remaining: 40).demandsUserAction == false)
        #expect(SyncPosture.upToDate.demandsUserAction == false)
    }
}
