import SwiftUI
import StoreKit
import Security

@MainActor final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()
    static let monthlyID = "com.maroon.CloudChess.unlimited.monthly"
    @Published private(set) var product: Product?
    @Published private(set) var unlimited = false
    @Published private(set) var checking = true
    @Published private(set) var purchasing = false
    @Published private(set) var loadingProduct = false
    @Published private(set) var message: String?
    @Published private(set) var allowance = PuzzleAllowance()
    @Published private(set) var storageReady = false
    private var updates: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var entitlementRevision = 0
    private let clockDate = Date()
    private let clockUptime = ProcessInfo.processInfo.systemUptime
    private let service = "com.maroon.CloudChess.free-puzzles.v1"
    private var testDefaults: UserDefaults?
    private var bypassAllowance = false

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            testDefaults = UserDefaults(suiteName: "com.maroon.CloudChess.subscription-tests")
            bypassAllowance = !ProcessInfo.processInfo.arguments.contains("--monetization-testing")
            if !ProcessInfo.processInfo.arguments.contains("--preserve-allowance") { testDefaults?.removeObject(forKey: service) }
        }
        #endif
        do {
            if let data = try readLedger() { allowance = try JSONDecoder().decode(PuzzleAllowance.self, from: data) }
            storageReady = true
        } catch { message = "Your free puzzles couldn’t be loaded. Please try again." }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--quota-exhausted"), testDefaults != nil {
            for n in 0..<3 { allowance.admit(session: "fixture-\(n)", unlimited: false, at: now) }
            try? persist(allowance)
        }
        #endif
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = result,
                      transaction.productID == Self.monthlyID else { continue }
                await self?.refreshEntitlements()
                await transaction.finish()
            }
        }
    }
    // Monotonic within a process; cross-device/reinstall quotas require an account/server.
    var now: Date { max(Date(), clockDate.addingTimeInterval(max(0, ProcessInfo.processInfo.systemUptime-clockUptime))) }
    var remaining: Int { allowance.remaining(at: now) }
    var nextAvailable: Date? { allowance.nextAvailable(at: now) }
    var canStartPuzzle: Bool { !checking && storageReady && (bypassAllowance || unlimited || remaining > 0) }

    func start() async {
        if startup != nil { while checking { do { try await Task.sleep(for: .milliseconds(30)) } catch { return } }; return }
        let task = Task {
            // StoreKit reconciliation must not strand the free game on launch.
            // Remain free (never assume paid access) if the system is slow.
            let deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.checking = false
            }
            await refreshEntitlements(); deadline.cancel()
        }
        startup = task
        Task { await loadProduct() }
        while checking { do { try await Task.sleep(for: .milliseconds(30)) } catch { return } }
    }
    func refreshEntitlements() async {
        entitlementRevision += 1
        let revision = entitlementRevision
        var active = false
        var nextCheck: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.monthlyID,
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            // currentEntitlements includes subscribed and billing-grace-period access.
            active = true
            if let end = transaction.expirationDate, end > now { nextCheck = end }
        }
        guard revision == entitlementRevision else { return }
        unlimited = active; checking = false
        if active { message = nil }
        expiry?.cancel()
        // Reconcile on expiry, foreground, transaction updates, and once a minute
        // while active (including a grace period whose transaction date has passed).
        let delay = min(60, max(1, nextCheck?.timeIntervalSince(now) ?? 60))
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.refreshEntitlements()
        }
    }
    func loadProduct() async {
        guard !loadingProduct else { return }
        loadingProduct = true; message = nil
        defer { loadingProduct = false }
        do {
            let products = try await Product.products(for: [Self.monthlyID])
            product = products.first { $0.id == Self.monthlyID && $0.type == .autoRenewable && $0.subscription?.subscriptionPeriod.unit == .month && $0.subscription?.subscriptionPeriod.value == 1 }
            if product == nil { message = "Subscriptions aren’t available right now. You can keep playing when your free puzzles refill." }
        } catch { message = "The App Store couldn’t be reached. Check your connection and try again." }
    }
    func purchase() async {
        guard !purchasing, let product else { return }
        purchasing = true; message = nil
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result, transaction.productID == Self.monthlyID else {
                    message = "Apple couldn’t verify this purchase. Try Restore purchases."; return
                }
                await refreshEntitlements()
                await transaction.finish()
                if !unlimited { message = "Your purchase is being confirmed. Please try Restore purchases shortly." }
            case .pending: message = "Waiting for Apple’s approval. Unlimited puzzles will unlock automatically when approved."
            case .userCancelled: break
            @unknown default: message = "The purchase wasn’t completed. Please try again."
            }
        } catch { message = "The purchase wasn’t completed. Please try again or restore your purchases." }
    }
    func restore() async {
        guard !purchasing else { return }
        purchasing = true; message = nil
        defer { purchasing = false }
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !unlimited { message = "No active subscription was found for this Apple Account." }
        } catch { message = "Purchases couldn’t be restored. Please try again." }
    }
    func retry() async {
        do {
            if let data = try readLedger() { allowance = try JSONDecoder().decode(PuzzleAllowance.self, from: data) }
            storageReady = true; message = nil
        } catch { storageReady = false; message = "Your free puzzles couldn’t be loaded. Please try again." }
        await refreshEntitlements(); await loadProduct()
    }
    func admit(session: String) throws {
        guard storageReady else { throw AccessError.storage }
        var next = allowance
        guard next.admit(session: session, unlimited: unlimited || bypassAllowance, at: now) else { throw AccessError.exhausted }
        try persist(next) // Never grant a new puzzle if durable storage fails.
        allowance = next
    }
    enum AccessError: Error { case exhausted, storage }
    private var key: [String: Any] { [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:"allowance"] }
    private func readLedger() throws -> Data? {
        if let testDefaults { return testDefaults.data(forKey: service) }
        var query = key; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AccessError.storage }
        return data
    }
    private func persist(_ ledger: PuzzleAllowance) throws {
        let data = try JSONEncoder().encode(ledger)
        if let testDefaults { testDefaults.set(data, forKey: service); return }
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = key; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AccessError.storage }
        } else if status != errSecSuccess { throw AccessError.storage }
    }
}

struct UnlimitedPuzzlePanel: View {
    @ObservedObject var store: SubscriptionStore
    let waiting: Bool
    let close: () -> Void
    let continuePlaying: () -> Void
    @State private var manage = false
    var body: some View {
        CloudPopup(title: store.unlimited ? "Unlimited puzzles" : "Keep playing", symbol: "cloud.fill", dismiss: close) {
            VStack(alignment: .leading, spacing: 14) {
                if store.unlimited {
                    Text("Your subscription is active.").font(.headline)
                } else {
                    Text("3 free puzzles every hour. Unlimited puzzles with CloudChess Unlimited.").font(.body)
                    if let product = store.product { Text("\(product.displayPrice) / month").font(.title2.bold()).accessibilityIdentifier("subscription-price") }
                    else if store.loadingProduct { ProgressView().accessibilityLabel("Loading subscription price") }
                    if waiting {
                        TimelineView(.periodic(from: .now, by: 10)) { _ in
                            if let next = store.nextAvailable {
                                Text("Next free puzzle at \(next.formatted(date: .omitted, time: .shortened)).").font(.footnote)
                            } else { Text("Your free puzzle is ready.").font(.footnote) }
                        }
                    }
                    Text("Renews monthly until canceled. Payment is charged to your Apple Account. Cancel in Settings at least 24 hours before renewal.").font(.caption).foregroundStyle(.secondary)
                }
                if let message = store.message { Text(message).font(.footnote).accessibilityIdentifier("subscription-message") }
                HStack(spacing: 24) {
                    Link("Privacy", destination: URL(string: "https://kostakarathana.github.io/cloudchess-support/privacy.html")!).frame(minHeight:44)
                    Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!).frame(minHeight:44)
                }.font(.footnote).frame(minHeight:44)
            }
        } actions: {
            VStack(spacing: 8) {
                if store.unlimited {
                    Button("Continue", action: continuePlaying).buttonStyle(CloudActionStyle()).accessibilityIdentifier("subscription-continue")
                    Button("Manage subscription") { manage = true }.frame(minHeight:44)
                } else {
                    Button { Task { await store.purchase() } } label: {
                        HStack { if store.purchasing { ProgressView().tint(.white) }; Text(store.product.map { "Subscribe · \($0.displayPrice) / month" } ?? "Subscription unavailable") }.frame(maxWidth: .infinity)
                    }.buttonStyle(CloudActionStyle()).disabled(store.purchasing || store.product == nil || store.checking).accessibilityIdentifier("subscription-buy")
                    HStack {
                        Button("Restore purchases") { Task { await store.restore() } }.frame(minHeight:44).accessibilityIdentifier("subscription-restore")
                        Spacer()
                        Button("Retry") { Task { await store.retry() } }.frame(minHeight:44).accessibilityIdentifier("subscription-retry")
                    }.font(.footnote).frame(minHeight:44).disabled(store.purchasing)
                    if waiting {
                        TimelineView(.periodic(from: .now, by: 10)) { _ in
                            if store.canStartPuzzle { Button("Play free puzzle", action: continuePlaying).frame(minHeight:44).accessibilityIdentifier("subscription-free") }
                        }
                    }
                }
            }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }.manageSubscriptionsSheet(isPresented: $manage)
        .task { await store.start(); if store.product == nil { await store.loadProduct() } }
        .accessibilityIdentifier("subscription-panel")
    }
}
