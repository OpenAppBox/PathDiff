//
//  SubscriptionStore.swift
//  PathDiff
//

import AppKit
import Foundation
import OSLog
import StoreKit

/// Whether PathDiff may be used: it needs an active yearly subscription (the first week is a
/// free trial offered by the App Store). Family Sharing members count as subscribed.
@Observable
final class SubscriptionStore {
    enum Access: Equatable {
        /// Not checked yet (only for a moment after launch).
        case checking
        case subscribed
        case notSubscribed
    }

    static let shared = SubscriptionStore()

    /// The auto-renewable yearly subscription, configured in App Store Connect.
    nonisolated static let productID = "com.openappbox.pathdiff.yearly"
    nonisolated static let privacyPolicyURL = URL(string: "https://openappbox.com/privacy")!
    /// Apple's standard license agreement, which PathDiff uses as its terms of use.
    nonisolated static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// The App Store's subscription management page (the in-app sheet isn't available on macOS).
    nonisolated static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    private(set) var access = Access.checking

    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.openappbox.pathdiff", category: "Subscription")

    /// Checks the current entitlement and follows changes (purchases, renewals, expiry,
    /// refunds, Family Sharing) for as long as the app runs.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            await self?.refresh()
            for await _ in Transaction.updates {
                await self?.refresh()
            }
        }
    }

    /// Re-reads the entitlement from StoreKit. Works offline: StoreKit keeps verified
    /// transactions on the Mac.
    func refresh() async {
        #if DEBUG
        // For screenshots of the subscription offer: the PathDiff scheme has this launch
        // argument (off by default) under Run ▸ Arguments. Debug builds only.
        if UserDefaults.standard.bool(forKey: "PathDiffShowSubscriptionOffer") {
            access = .notSubscribed
            return
        }
        #endif
        var isSubscribed = false
        for await result in Transaction.currentEntitlements(for: Self.productID) {
            guard case .verified(let transaction) = result else {
                logger.error("Ignoring an unverified transaction")
                continue
            }
            if Self.grantsAccess(revocationDate: transaction.revocationDate, expirationDate: transaction.expirationDate) {
                isSubscribed = true
            }
        }
        access = isSubscribed ? .subscribed : .notSubscribed
    }

    /// Whether a transaction for the subscription unlocks PathDiff `now`.
    nonisolated static func grantsAccess(revocationDate: Date?, expirationDate: Date?, now: Date = .now) -> Bool {
        guard revocationDate == nil else { return false }
        guard let expirationDate else { return true }
        return expirationDate > now
    }

    func manageSubscription() {
        NSWorkspace.shared.open(Self.manageSubscriptionsURL)
    }
}
