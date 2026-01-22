import SwiftUI
import StoreKit

struct TipJarView: View {
    @ObservedObject private var tipManager = TipJarManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Text("Support QuickMD")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("QuickMD is free and always will be. If you find it useful, consider leaving a tip!")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            Divider()

            // Products
            if tipManager.isLoading {
                ProgressView("Loading...")
                    .frame(height: 120)
            } else if tipManager.products.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Unable to load tip options")
                        .foregroundColor(.secondary)
                    Button("Try Again") {
                        Task { await tipManager.loadProducts() }
                    }
                }
                .frame(height: 120)
            } else {
                HStack(spacing: 16) {
                    ForEach(tipManager.products, id: \.id) { product in
                        TipButton(product: product, manager: tipManager)
                    }
                }
            }

            // Status messages
            switch tipManager.purchaseState {
            case .purchasing:
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Processing...")
                }
                .foregroundColor(.secondary)

            case .purchased:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Thank you for your support!")
                        .fontWeight(.medium)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        tipManager.resetPurchaseState()
                    }
                }

            case .failed(let message):
                HStack {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text(message)
                        .font(.caption)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        tipManager.resetPurchaseState()
                    }
                }

            case .ready:
                EmptyView()
            }

            Spacer()

            // Footer
            Text("Tips are one-time purchases. Thank you!")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
        .frame(width: 400, height: 320)
        .task {
            if tipManager.products.isEmpty {
                await tipManager.loadProducts()
            }
        }
    }
}

struct TipButton: View {
    let product: Product
    @ObservedObject var manager: TipJarManager
    @State private var isHovering = false

    var body: some View {
        Button {
            Task { await manager.purchase(product) }
        } label: {
            VStack(spacing: 8) {
                Text(product.emoji)
                    .font(.system(size: 32))

                Text(product.tipName)
                    .font(.caption)
                    .fontWeight(.medium)

                Text(product.displayPrice)
                    .font(.subheadline)
                    .fontWeight(.bold)
            }
            .frame(width: 100, height: 100)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovering ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovering ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .disabled(manager.purchaseState == .purchasing)
    }
}

#Preview {
    TipJarView()
}
