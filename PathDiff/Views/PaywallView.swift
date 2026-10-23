//
//  PaywallView.swift
//  PathDiff
//

import StoreKit
import SwiftUI

/// Shown in place of a comparison window until PathDiff is subscribed: what PathDiff does,
/// and the App Store's subscription sheet (free week, price, Restore Purchases, terms and
/// privacy links).
struct PaywallView: View {
    let store: SubscriptionStore

    var body: some View {
        SubscriptionStoreView(productIDs: [SubscriptionStore.productID]) {
            marketing
        }
        .subscriptionStoreButtonLabel(.multiline)
        .storeButton(.visible, for: .restorePurchases)
        // The offer stands in for the window's contents, so there's nothing to go back to.
        .storeButton(.hidden, for: .cancellation)
        .subscriptionStorePolicyDestination(url: SubscriptionStore.termsOfUseURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: SubscriptionStore.privacyPolicyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, _ in
            await store.refresh()
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private var marketing: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text(verbatim: "PathDiff")
                    .font(.largeTitle.weight(.bold))
                Text("See exactly what’s different between two folders, then make them match.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 10) {
                benefit("square.split.2x1", "Every difference sorted into modified, moved, missing and extra, with sizes")
                benefit("photo.on.rectangle.angled", "Code, photos and videos compared side by side")
                benefit("arrow.triangle.2.circlepath", "Sync with a preview, undo and Sync History")
                benefit("lock.shield", "Private: works offline and only sees the folders you choose")
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
        .padding(.top, 24)
        .padding(.horizontal, 32)
    }

    private func benefit(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
        }
    }
}

/// The comparison window, or the subscription offer when PathDiff isn't subscribed.
struct SubscriptionGate<Content: View>: View {
    let store: SubscriptionStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch store.access {
        case .subscribed:
            content()
        case .notSubscribed:
            PaywallView(store: store)
        case .checking:
            // Usually a fraction of a second; avoids flashing the offer at subscribers.
            ProgressView()
                .frame(minWidth: 640, minHeight: 560)
        }
    }
}
