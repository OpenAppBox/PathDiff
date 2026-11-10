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
    /// The newest transaction StoreKit delivered this session (a purchase or an update). Right
    /// after a purchase, `Transaction.latest` can still return the previous one for a moment.
    @ObservationIgnored private var newest: Transaction?
    @ObservationIgnored private var expiryCheck: Task<Void, Never>?
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private let logger = Logger(subsystem: "com.openappbox.pathdiff", category: "Subscription")

    /// Checks the subscription and follows changes (renewals, expiry, refunds, Family Sharing,
    /// Ask to Buy approvals, purchases on another Mac) for as long as the app runs.
    func start() {
        guard updates == nil else { return }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else {
                    self?.logger.error("Ignoring an unverified transaction update")
                    continue
                }
                await transaction.finish()
                await self?.apply(transaction)
            }
        }
        // A long session also notices cancellations: check again when PathDiff comes to the
        // front, at most once an hour.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.lastRefresh) > 3_600 else { return }
                Task { await self.refresh() }
            }
        }
        Task {
            for await result in Transaction.unfinished {
                if case .verified(let transaction) = result { await transaction.finish() }
            }
            await refresh()
        }
    }

    /// Reads the subscription from StoreKit's latest transaction for the product. Works offline:
    /// StoreKit keeps verified transactions on the Mac.
    func refresh() async {
        lastRefresh = Date()
        #if DEBUG
        // For screenshots of the subscription offer: the PathDiff scheme has this launch
        // argument (off by default) under Run ▸ Arguments. Debug builds only.
        if UserDefaults.standard.bool(forKey: "PathDiffShowSubscriptionOffer") && newest == nil {
            access = .notSubscribed
            return
        }
        #endif
        var candidate: Transaction?
        if let result = await Transaction.latest(for: Self.productID) {
            if case .verified(let latest) = result {
                candidate = latest
            } else {
                logger.error("Ignoring an unverified transaction")
            }
        }
        if let newest, newest.purchaseDate > (candidate?.purchaseDate ?? .distantPast) {
            candidate = newest
        }
        guard let candidate else {
            access = .notSubscribed
            return
        }
        update(from: candidate)
    }

    /// The subscription offer's purchase result. A completed purchase unlocks PathDiff at once:
    /// the purchase never arrives through `Transaction.updates`, and `Transaction.latest` and the
    /// entitlements can take a moment to include it.
    func purchaseCompleted(_ result: Result<Product.PurchaseResult, any Error>) async {
        switch result {
        case .success(.success(.verified(let transaction))):
            await transaction.finish()
            await apply(transaction)
        case .success(.success(.unverified)):
            logger.error("The purchase's transaction couldn't be verified")
            await refresh()
        case .success(.pending):
            // Ask to Buy or a payment that needs action; the approval arrives as an update.
            logger.info("Purchase pending")
        case .success(.userCancelled):
            break
        case .failure(let error):
            logger.error("Purchase failed: \(error.localizedDescription, privacy: .public)")
            await refresh()
        @unknown default:
            await refresh()
        }
    }

    /// A transaction StoreKit just delivered (a purchase, renewal or refund) decides at once.
    func apply(_ transaction: Transaction) async {
        guard transaction.productID == Self.productID else { return }
        update(from: transaction)
    }

    private func update(from transaction: Transaction) {
        if transaction.purchaseDate >= (newest?.purchaseDate ?? .distantPast) { newest = transaction }
        let granted = Self.grantsAccess(revocationDate: transaction.revocationDate, expirationDate: transaction.expirationDate)
        access = granted ? .subscribed : .notSubscribed
        if granted { scheduleExpiryCheck(transaction.expirationDate) }
    }

    /// Whether a transaction for the subscription unlocks PathDiff `now`.
    nonisolated static func grantsAccess(revocationDate: Date?, expirationDate: Date?, now: Date = .now) -> Bool {
        guard revocationDate == nil else { return false }
        guard let expirationDate else { return true }
        return expirationDate > now
    }

    /// An expiry doesn't always arrive as a transaction update while PathDiff is open; check again
    /// shortly after the current period ends (a renewal by then is the latest transaction).
    private func scheduleExpiryCheck(_ expires: Date?) {
        expiryCheck?.cancel()
        guard let expires, expires > Date() else { return }
        let delay = expires.timeIntervalSinceNow + 60
        expiryCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func manageSubscription() {
        NSWorkspace.shared.open(Self.manageSubscriptionsURL)
    }
}
