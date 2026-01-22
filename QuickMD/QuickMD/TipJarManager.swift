import StoreKit
import os

@MainActor
class TipJarManager: ObservableObject {
    static let shared = TipJarManager()

    @Published var products: [Product] = []
    @Published var isLoading = false
    @Published var purchaseState: PurchaseState = .ready

    enum PurchaseState: Equatable {
        case ready
        case purchasing
        case purchased
        case failed(String)
    }

    private let productIDs: Set<String> = [
        "pl.falami.studio.QuickMD.tip.small",
        "pl.falami.studio.QuickMD.tip.medium",
        "pl.falami.studio.QuickMD.tip.large"
    ]

    private let logger = Logger(subsystem: "pl.falami.studio.QuickMD", category: "TipJar")

    private init() {}

    func loadProducts() async {
        isLoading = true

        do {
            let storeProducts = try await Product.products(for: productIDs)
            products = storeProducts.sorted { $0.price < $1.price }
        } catch {
            logger.error("Failed to load products: \(error.localizedDescription)")
            products = []
        }

        isLoading = false
    }

    func purchase(_ product: Product) async {
        purchaseState = .purchasing

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    purchaseState = .purchased
                case .unverified(_, let error):
                    purchaseState = .failed("Verification failed: \(error.localizedDescription)")
                }
            case .userCancelled:
                purchaseState = .ready
            case .pending:
                purchaseState = .ready
            @unknown default:
                purchaseState = .ready
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func resetPurchaseState() {
        purchaseState = .ready
    }
}

extension Product {
    var emoji: String {
        switch id {
        case "pl.falami.studio.QuickMD.tip.small":
            return "☕"
        case "pl.falami.studio.QuickMD.tip.medium":
            return "🍕"
        case "pl.falami.studio.QuickMD.tip.large":
            return "🎉"
        default:
            return "💝"
        }
    }

    var tipName: String {
        switch id {
        case "pl.falami.studio.QuickMD.tip.small":
            return "Small Tip"
        case "pl.falami.studio.QuickMD.tip.medium":
            return "Medium Tip"
        case "pl.falami.studio.QuickMD.tip.large":
            return "Large Tip"
        default:
            return displayName
        }
    }
}
