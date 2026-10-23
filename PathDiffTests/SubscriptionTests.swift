//
//  SubscriptionTests.swift
//  PathDiffTests
//

import Foundation
import Testing

@Suite("Subscription")
struct SubscriptionTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func activeSubscriptionGrantsAccess() {
        #expect(SubscriptionStore.grantsAccess(revocationDate: nil, expirationDate: now.addingTimeInterval(86_400), now: now))
    }

    /// The free week is an introductory offer of the subscription: it expires like any period.
    @Test func expiredTrialOrPeriodDoesNot() {
        #expect(!SubscriptionStore.grantsAccess(revocationDate: nil, expirationDate: now.addingTimeInterval(-1), now: now))
    }

    /// Refunded or revoked (for example a family member leaving the Family Sharing group).
    @Test func revokedSubscriptionDoesNot() {
        #expect(!SubscriptionStore.grantsAccess(revocationDate: now.addingTimeInterval(-60), expirationDate: now.addingTimeInterval(86_400), now: now))
    }

    @Test func productAndLinksAreConfigured() {
        #expect(SubscriptionStore.productID == "com.openappbox.pathdiff.yearly")
        #expect(SubscriptionStore.privacyPolicyURL.absoluteString == "https://openappbox.com/privacy")
        #expect(SubscriptionStore.termsOfUseURL.host() == "www.apple.com")
    }
}
