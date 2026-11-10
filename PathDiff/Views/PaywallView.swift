//
//  PaywallView.swift
//  PathDiff
//

import StoreKit
import SwiftUI

/// Shown in place of a comparison window until PathDiff is subscribed: what PathDiff does,
/// and the App Store's subscription sheet (price, Restore Purchases, terms and privacy links).
/// The billed amount is the most prominent pricing element (App Review 3.1.2(c)): the header
/// shows it large and the purchase button names it, never the product's display name. The free
/// week, for those StoreKit says are eligible, is a smaller line under the price.
struct PaywallView: View {
    let store: SubscriptionStore
    @State private var price: String?
    @State private var freeWeek = false

    var body: some View {
        SubscriptionStoreView(productIDs: [SubscriptionStore.productID]) {
            marketing
        }
        // The button shows the price ("$3.00/year").
        .subscriptionStoreButtonLabel(.action.price)
        .storeButton(.visible, for: .restorePurchases)
        // The offer stands in for the window's contents, so there's nothing to go back to.
        .storeButton(.hidden, for: .cancellation)
        .subscriptionStorePolicyDestination(url: SubscriptionStore.termsOfUseURL, for: .termsOfService)
        .subscriptionStorePolicyDestination(url: SubscriptionStore.privacyPolicyURL, for: .privacyPolicy)
        .onInAppPurchaseCompletion { _, result in
            await store.purchaseCompleted(result)
        }
        .frame(minWidth: 640, minHeight: 560)
        .task {
            guard let product = try? await Product.products(for: [SubscriptionStore.productID]).first else { return }
            price = product.displayPrice
            if let subscription = product.subscription, let offer = subscription.introductoryOffer,
               offer.paymentMode == .freeTrial, offer.period.unit == .week, offer.period.value == 1 {
                freeWeek = await subscription.isEligibleForIntroOffer
            }
        }
    }

    private var marketing: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(verbatim: "PathDiff")
                    .font(.title.weight(.semibold))
                if let price {
                    Text("\(price) per year", comment: "Subscription offer: the yearly price, shown large (e.g. “$3.00 per year”)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if freeWeek {
                        Text("The first week is free. Cancel before it ends and you won’t be charged.", comment: "Subscription offer: the 1-week free trial, shown smaller than the price and only to people eligible for it")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.center)
                    }
                    // StoreKit leaves out its renewal line when the button shows the price.
                    Text("Renews automatically every year until you cancel.", comment: "Subscription offer: the renewal terms under the yearly price")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("See exactly what’s different between two folders, then make them match.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
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
