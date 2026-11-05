import SwiftUI
import StoreKit
import Security
import Network
import GoogleMobileAds
import UserMessagingPlatform

@MainActor final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()
    static let monthlyID = "com.maroon.CloudChess.unlimited.monthly"
    static let annualID = "com.maroon.CloudChess.unlimited.annual"
    static let productIDs: Set<String> = [monthlyID, annualID]
    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var unlimited = false
    @Published private(set) var checking = true
    @Published private(set) var purchasing = false
    @Published private(set) var loadingProduct = false
    @Published private(set) var message: String?
    /// Apple decides intro-offer eligibility per subscription group.
    @Published private(set) var trialEligible = true
    @Published private(set) var allowance = AdAllowance()
    @Published private(set) var storageReady = false
    private var updates: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var entitlementRevision = 0
    private let clockDate = Date()
    private let clockUptime = ProcessInfo.processInfo.systemUptime
    private let service = "com.maroon.CloudChess.ad-allowance.v1"
    private var testDefaults: UserDefaults?
    private(set) var bypassAllowance = false

    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            testDefaults = UserDefaults(suiteName: "com.maroon.CloudChess.subscription-tests")
            bypassAllowance = !ProcessInfo.processInfo.arguments.contains("--monetization-testing")
            if !ProcessInfo.processInfo.arguments.contains("--preserve-allowance") { testDefaults?.removeObject(forKey: service) }
        }
        #endif
        do {
            if let data = try readLedger() { allowance = try JSONDecoder().decode(AdAllowance.self, from: data) }
            storageReady = true
        } catch { message = "Your free puzzles couldn’t be loaded. Please try again." }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ad-break-due"), testDefaults != nil {
            // An introduction already played long ago, with no puzzles left.
            let past = now.addingTimeInterval(-7200)
            allowance = AdAllowance()
            for n in 0..<AdAllowance.introPuzzles { allowance.admit(session: "fixture-\(n)", unlimited: false, at: past) }
            try? persist(allowance)
        }
        #endif
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard case .verified(let transaction) = result,
                      Self.productIDs.contains(transaction.productID) else { continue }
                await self?.refreshEntitlements()
                await transaction.finish()
            }
        }
    }
    // Monotonic within a process; cross-device/reinstall quotas require an account/server.
    var now: Date { max(Date(), clockDate.addingTimeInterval(max(0, ProcessInfo.processInfo.systemUptime-clockUptime))) }
    var monthly: Product? { products[Self.monthlyID] }
    var annual: Product? { products[Self.annualID] }
    /// Rounded down so the yearly plan is never advertised as cheaper than it is.
    var annualSavingsPercent: Int? {
        guard let monthly, let annual else { return nil }
        return PlanPricing.savingsPercent(monthly: monthly.price, annual: annual.price)
    }
    func freeTrial(_ product: Product?) -> Product.SubscriptionPeriod? {
        guard trialEligible, let offer = product?.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        return offer.period
    }
    /// What the Premium card shows for each plan, yearly first.
    struct PlanOption: Identifiable, Equatable {
        let id: String, price: String, yearly: Bool
        let trialLength: String?, trialDuration: String?
    }
    var planOptions: [PlanOption] {
        #if DEBUG
        // App Review screenshot fixture: the simulator's StoreKit test catalog cannot be relied on.
        if ProcessInfo.processInfo.arguments.contains("--premium-preview") {
            return [PlanOption(id: Self.annualID, price: "$59.99", yearly: true, trialLength: "1-month", trialDuration: "1 month"),
                    PlanOption(id: Self.monthlyID, price: "$7.99", yearly: false, trialLength: "7-day", trialDuration: "7 days")]
        }
        #endif
        return [annual, monthly].compactMap { $0 }.map { product in
            let trial = freeTrial(product)
            return PlanOption(id: product.id, price: product.displayPrice, yearly: product.id == Self.annualID, trialLength: trial?.trialLength, trialDuration: trial?.trialDuration)
        }
    }
    var savingsBadge: Int? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--premium-preview") { return PlanPricing.savingsPercent(monthly: Decimal(string: "7.99")!, annual: Decimal(string: "59.99")!) }
        #endif
        return annualSavingsPercent
    }
    func purchase(planID: String) async {
        guard let product = products[planID] else { return }
        await purchase(product)
    }
    var needsAdBreak: Bool { !bypassAllowance && !unlimited && allowance.needsBreak(at: now) }
    var canStartPuzzle: Bool { !checking && storageReady && (bypassAllowance || unlimited || !allowance.needsBreak(at: now)) }

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
        Task { await loadProducts() }
        while checking { do { try await Task.sleep(for: .milliseconds(30)) } catch { return } }
    }
    func refreshEntitlements() async {
        entitlementRevision += 1
        let revision = entitlementRevision
        var active = false
        var nextCheck: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            // currentEntitlements includes subscribed and billing-grace-period access.
            active = true
            if let end = transaction.expirationDate, end > now { nextCheck = min(nextCheck ?? end, end) }
        }
        guard revision == entitlementRevision else { return }
        unlimited = active; checking = false
        if active { message = nil }
        if let group = (monthly ?? annual)?.subscription?.subscriptionGroupID {
            trialEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: group)
        }
        expiry?.cancel()
        // Reconcile on expiry, foreground, transaction updates, and once a minute
        // while active (including a grace period whose transaction date has passed).
        let delay = min(60, max(1, nextCheck?.timeIntervalSince(now) ?? 60))
        expiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.refreshEntitlements()
        }
    }
    func loadProducts() async {
        guard !loadingProduct else { return }
        loadingProduct = true; message = nil
        defer { loadingProduct = false }
        do {
            var found: [String: Product] = [:]
            for product in try await Product.products(for: Self.productIDs) where product.type == .autoRenewable {
                guard let period = product.subscription?.subscriptionPeriod, period.value == 1 else { continue }
                if product.id == Self.monthlyID && period.unit == .month { found[product.id] = product }
                if product.id == Self.annualID && period.unit == .year { found[product.id] = product }
            }
            products = found
            if let group = found.values.first?.subscription?.subscriptionGroupID {
                trialEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: group)
            }
            if found.isEmpty { message = "Subscriptions aren’t available right now. Please try again later." }
        } catch { message = "The App Store couldn’t be reached. Check your connection and try again." }
    }
    func purchase(_ product: Product) async {
        guard !purchasing else { return }
        purchasing = true; message = nil
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result, Self.productIDs.contains(transaction.productID) else {
                    message = "Apple couldn’t verify this purchase. Try Restore purchases."; return
                }
                await refreshEntitlements()
                await transaction.finish()
                if !unlimited { message = "Your purchase is being confirmed. Please try Restore purchases shortly." }
            case .pending: message = "Waiting for Apple’s approval. Premium will unlock automatically when approved."
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
            if let data = try readLedger() { allowance = try JSONDecoder().decode(AdAllowance.self, from: data) }
            storageReady = true; message = nil
        } catch { storageReady = false; message = "Your free puzzles couldn’t be loaded. Please try again." }
        await refreshEntitlements(); await loadProducts()
    }
    private var ledgerWrite: Task<Void, Error>?
    /// Ledger writes are serialized; the Keychain write runs on a utility queue
    /// so securityd IPC never sits on the main actor during a handoff. The
    /// ledger only changes after that write succeeds (never grant on storage
    /// failure), and admission stays idempotent per session ID.
    private func update(_ change: @escaping (inout AdAllowance) throws -> Void) async throws {
        let previous = ledgerWrite
        let task = Task<Void, Error> { [self] in
            _ = try? await previous?.value
            guard storageReady else { throw AccessError.storage }
            var next = allowance
            try change(&next)
            let data = try JSONEncoder().encode(next)
            let key = self.key, defaults = testDefaults, service = self.service
            try await Task.detached(priority: .utility) { try Self.writeLedger(data, key: key, defaults: defaults, service: service) }.value
            allowance = next
        }
        ledgerWrite = task
        defer { if ledgerWrite == task { ledgerWrite = nil } }
        try await task.value
    }
    func admit(session: String) async throws {
        let paid = unlimited || bypassAllowance, at = now
        try await update { ledger in
            guard ledger.admit(session: session, unlimited: paid, at: at) else { throw AccessError.adBreak }
        }
    }
    /// The batch sizes shown on the break stay fixed until one is watched.
    func prepareOffer(recent: [Double]) async throws -> AdAllowance.Offer {
        if let offer = allowance.offer { return offer }
        try await update { ledger in _ = ledger.prepareOffer(recent: recent) }
        return allowance.offer ?? AdAllowance.offer(recent: recent)
    }
    func grant(_ kind: AdAllowance.Break) async throws {
        let at = now
        try await update { $0.grant(kind, at: at) }
    }
    enum AccessError: Error { case adBreak, storage }
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
    private func persist(_ ledger: AdAllowance) throws {
        try Self.writeLedger(try JSONEncoder().encode(ledger), key: key, defaults: testDefaults, service: service)
    }
    nonisolated private static func writeLedger(_ data: Data, key: [String: Any], defaults: UserDefaults?, service: String) throws {
        if let defaults { defaults.set(data, forKey: service); return }
        let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = key; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AccessError.storage }
        } else if status != errSecSuccess { throw AccessError.storage }
    }
}

/// Free play depends on ads, which need a connection. Subscribers stay offline-capable.
@MainActor final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    @Published private(set) var online = true
    private let monitor = NWPathMonitor()
    private init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--offline") { online = false; return }
        #endif
        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in Connectivity.shared.online = satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "CloudChess.connectivity", qos: .utility))
    }
}

/// The rewarded-ad network seam (`GoogleRewardedAds` in shipping builds). A
/// no-fill while online shows CloudChess's own Premium house ad and still grants
/// the batch. `show()` returns `.rewarded` after the reward callback, `.dismissed`
/// when the player closes early (no grant), `.noFill` when nothing loads.
enum RewardedAdResult { case rewarded, dismissed, noFill }
@MainActor protocol RewardedAdService { func show() async -> RewardedAdResult }
struct NoFillAdService: RewardedAdService { func show() async -> RewardedAdResult { .noFill } }

/// Google AdMob rewarded ads with Google's consent SDK (UMP). Info.plist holds
/// `GADApplicationIdentifier` and `CloudChessRewardedAdUnit`; while either is
/// empty every request is a no-fill (house ad). The SDK and its consent/ATT
/// messages start lazily, from a player's fifth puzzle, never at launch.
@MainActor final class GoogleRewardedAds: NSObject, ObservableObject, RewardedAdService, FullScreenContentDelegate {
    static let shared = GoogleRewardedAds()
    private let unit: String = {
        #if DEBUG
        // Google's sample rewarded unit: development builds never request live ads.
        return "ca-app-pub-3940256099942544/1712485313"
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "CloudChessRewardedAdUnit") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }()
    private let app = (Bundle.main.object(forInfoDictionaryKey: "GADApplicationIdentifier") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    private var ad: RewardedAd?
    private var starting = false, started = false, loading = false, rewarded = false, retries = 0
    private var pending: CheckedContinuation<RewardedAdResult, Never>?
    @Published private(set) var privacyOptionsRequired = false
    var configured: Bool { !unit.isEmpty && !app.isEmpty }
    /// Diagnostic only: off, consent, started, loaded or showing.
    var status: String { pending != nil ? "showing" : ad != nil ? "loaded" : started ? "started" : starting ? "consent" : "off" }
    func prepare() {
        guard configured, !starting else { return }
        starting = true
        Task { await gatherConsentAndStart() }
    }
    /// EEA/UK/Swiss consent (and the IDFA explainer before Apple's ATT prompt)
    /// come first; ads are requested only when Google says consent allows it.
    /// Declining limits ad personalization but never blocks free play.
    private func gatherConsentAndStart() async {
        trace("consent update")
        do { try await ConsentInformation.shared.requestConsentInfoUpdate(with: RequestParameters()) } catch { trace("consent update failed: \(error)") }
        trace("consent status \(ConsentInformation.shared.consentStatus.rawValue), form \(ConsentInformation.shared.formStatus.rawValue), presenter \(String(describing: Self.presenter()))")
        if let root = Self.presenter() { do { try await ConsentForm.loadAndPresentIfRequired(from: root) } catch { trace("consent form failed: \(error)") } }
        trace("consent done, canRequestAds \(ConsentInformation.shared.canRequestAds)")
        privacyOptionsRequired = ConsentInformation.shared.privacyOptionsRequirementStatus == .required
        guard ConsentInformation.shared.canRequestAds else { starting = false; return }
        _ = await MobileAds.shared.start()
        trace("SDK started")
        started = true; load()
    }
    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        NSLog("[CloudChessAds] %@", message())
        #endif
    }
    private func load() {
        guard started, !loading, ad == nil else { return }
        loading = true
        Task {
            do {
                let loaded = try await RewardedAd.load(with: unit, request: Request())
                loaded.fullScreenContentDelegate = self; ad = loaded; retries = 0; loading = false
                trace("ad loaded")
            } catch {
                trace("ad load failed: \(error)")
                // Exponential back-off (2…64 s), as Google recommends.
                retries += 1; loading = false
                try? await Task.sleep(for: .seconds(pow(2, Double(min(6, retries)))))
                load()
            }
        }
    }
    /// Only a loaded ad is shown; otherwise this break is a no-fill (house ad, batch still granted).
    func show() async -> RewardedAdResult {
        guard let ad, pending == nil, let root = Self.presenter() else { prepare(); load(); return .noFill }
        return await withCheckedContinuation { continuation in
            pending = continuation; rewarded = false
            ad.present(from: root) { [weak self] in self?.rewarded = true }
        }
    }
    func presentPrivacyOptions() async {
        guard let root = Self.presenter() else { return }
        try? await ConsentForm.presentPrivacyOptionsForm(from: root)
    }
    private func finish(_ result: RewardedAdResult) {
        let waiting = pending; pending = nil; ad = nil; waiting?.resume(returning: result); load()
    }
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) { finish(rewarded ? .rewarded : .dismissed) }
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) { finish(.noFill) }
    private static func presenter() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

extension Product.SubscriptionPeriod {
    /// "7-day" / "1-month" style lengths for trial disclosures.
    var trialLength: String {
        switch unit {
        case .day: return "\(value)-day"
        case .week: return value == 1 ? "7-day" : "\(value)-week"
        case .month: return "\(value)-month"
        case .year: return "\(value)-year"
        @unknown default: return "\(value)-period"
        }
    }
    /// "7 days" / "1 month" for the renewal disclosure.
    var trialDuration: String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        switch unit {
        case .day: return plural(value, "day")
        case .week: return value == 1 ? "7 days" : plural(value, "week")
        case .month: return plural(value, "month")
        case .year: return plural(value, "year")
        @unknown default: return plural(value, "period")
        }
    }
}

struct UnlimitedPuzzlePanel: View {
    @ObservedObject var store: SubscriptionStore
    let close: () -> Void
    @State private var manage = false
    @State private var choice = SubscriptionStore.annualID
    private let ink = Color(rgb:0x192E49)
    private var selected: SubscriptionStore.PlanOption? { store.planOptions.first { $0.id == choice } ?? store.planOptions.first }

    var body: some View {
        CloudPopup(title: "CloudChess Premium", symbol: "cloud.fill", dismiss: close) {
            VStack(alignment: .leading, spacing: 12) {
                benefit("infinity", "Unlimited puzzles")
                benefit("play.slash", "No ads")
                benefit("airplane", "Play fully offline")
                if store.unlimited {
                    Label("Premium is active", systemImage: "checkmark.seal.fill")
                        .font(.headline).padding(.top, 6).accessibilityIdentifier("subscription-active")
                } else if store.planOptions.isEmpty {
                    Group {
                        if store.loadingProduct { ProgressView().accessibilityLabel("Loading subscription prices") }
                        else { Text("Unavailable").font(.subheadline) }
                    }.frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.planOptions) { option in plan(option, badge: option.yearly ? store.savingsBadge.map { "Save \($0)%" } : nil) }
                    }.padding(.top, 6)
                }
                if let message = store.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, 4).dynamicTypeSize(...DynamicTypeSize.xxxLarge).accessibilityIdentifier("subscription-message")
                }
            }
        } actions: {
            VStack(spacing: 6) {
                if store.unlimited {
                    Button(action: close) { Text("Continue").frame(maxWidth: .infinity) }
                        .buttonStyle(CloudActionStyle()).accessibilityIdentifier("subscription-continue")
                } else {
                    Button { if let selected { Task { await store.purchase(planID: selected.id) } } } label: {
                        HStack(spacing: 8) {
                            if store.purchasing { ProgressView().tint(.white) }
                            Text(selected?.trialLength == nil ? "Subscribe" : "Start free trial")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(CloudActionStyle())
                        .disabled(store.purchasing || selected == nil || store.checking)
                        .accessibilityIdentifier("subscription-buy")
                    if let selected { Text(terms(selected)).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("subscription-terms") }
                }
                HStack(spacing: 16) {
                    Link("Privacy", destination: URL(string: "https://kostakarathana.github.io/cloudchess-support/privacy.html")!)
                    Link("Terms", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    if store.unlimited {
                        Button("Manage") { manage = true }.accessibilityLabel("Manage subscription")
                    } else {
                        Button("Restore") { Task { await store.restore() } }
                            .disabled(store.purchasing).accessibilityLabel("Restore purchases")
                            .accessibilityIdentifier("subscription-restore")
                    }
                }.font(.footnote).buttonStyle(CloudPressStyle()).frame(minHeight: 44)
                if store.message != nil && !store.unlimited {
                    Button("Try again") { Task { await store.retry() } }
                        .font(.footnote).frame(minHeight: 44).disabled(store.purchasing)
                        .accessibilityIdentifier("subscription-retry")
                }
            }.dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }.manageSubscriptionsSheet(isPresented: $manage)
        .task { await store.start(); if store.products.isEmpty { await store.loadProducts() } }
        .accessibilityIdentifier("subscription-panel")
    }
    private func benefit(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 26).accessibilityHidden(true)
            Text(title).font(.body.weight(.medium))
        }.dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
    private func plan(_ option: SubscriptionStore.PlanOption, badge: String?) -> some View {
        let picked = selected?.id == option.id, yearly = option.yearly
        return Button { choice = option.id } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle").font(.system(size: 22)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(yearly ? "Yearly" : "Monthly").font(.headline)
                        if let badge {
                            Text(badge).font(.caption.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color(rgb:0x2E8B57), in: Capsule()).accessibilityIdentifier("subscription-savings")
                        }
                    }
                    Text("\(option.price) / \(yearly ? "year" : "month")").font(.subheadline)
                        .accessibilityIdentifier(yearly ? "subscription-annual-price" : "subscription-price")
                    if let trial = option.trialLength {
                        Text("\(trial) free trial").font(.caption.weight(.semibold)).foregroundStyle(ink.opacity(0.7))
                    }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(picked ? Color(rgb:0xD6E7F6) : .white.opacity(0.55), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(picked ? ink.opacity(0.45) : .white.opacity(0.8), lineWidth: picked ? 1.5 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(CloudPressStyle())
            .accessibilityAddTraits(picked ? .isSelected : [])
            .accessibilityIdentifier(yearly ? "subscription-plan-annual" : "subscription-plan-monthly")
    }
    private func terms(_ option: SubscriptionStore.PlanOption) -> String {
        let period = option.yearly ? "year" : "month"
        if let trial = option.trialDuration {
            return "Free for \(trial), then \(option.price) per \(period). Auto-renews until canceled."
        }
        return "\(option.price) per \(period). Auto-renews until canceled."
    }
}

/// Offered every few puzzles to free players instead of a paywall.
struct AdBreakPanel: View {
    let offer: AdAllowance.Offer
    let busy: Bool
    let watch: (AdAllowance.Break) -> Void
    let premium: () -> Void
    private let ink = Color(rgb:0x192E49)
    var body: some View {
        CloudPopup(title: "Keep playing", symbol: "play.rectangle", dismiss: nil) {
            VStack(spacing: 12) {
                choice(.short, symbol: "play.circle.fill", title: "Watch a short ad", gain: offer.short)
                choice(.long, symbol: "play.rectangle.on.rectangle.fill", title: "Watch \(AdAllowance.longAds) ads in a row", gain: offer.long)
            }
        } actions: {
            Button(action: premium) {
                Label("Go ad-free with Premium", systemImage: "cloud.fill").frame(maxWidth: .infinity)
            }.font(.headline).buttonStyle(CloudPressStyle()).frame(minHeight: 48)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityIdentifier("ad-break-premium")
        }.accessibilityIdentifier("ad-break-panel")
    }
    private func choice(_ kind: AdAllowance.Break, symbol: String, title: String, gain: Int) -> some View {
        Button { watch(kind) } label: {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 28)).frame(width: 36).accessibilityHidden(true)
                Text(title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text("+\(gain)").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Image(systemName: "puzzlepiece.fill").font(.system(size: 15)).accessibilityHidden(true)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(kind == .long ? Color(rgb:0xD6E7F6) : .white.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(ink.opacity(kind == .long ? 0.25 : 0.1), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(CloudPressStyle()).disabled(busy)
            .accessibilityLabel("\(title), \(gain) more puzzles")
            .accessibilityIdentifier(kind == .short ? "ad-break-short" : "ad-break-long")
    }
}

/// Free play stops while offline: ads support it. Subscribers keep playing offline.
struct OfflinePanel: View {
    let premium: () -> Void
    let retry: () -> Void
    var body: some View {
        CloudPopup(title: "Hey!", symbol: "wifi.slash", dismiss: nil) {
            Text("While this app does run offline, we rely on ads to support the app. Please either subscribe or turn on data.")
                .font(.body).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("offline-message")
        } actions: {
            VStack(spacing: 8) {
                Button(action: premium) { Text("Subscribe").frame(maxWidth: .infinity) }
                    .buttonStyle(CloudActionStyle()).accessibilityIdentifier("offline-subscribe")
                Button(action: retry) { Label("Try again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 48) }
                    .font(.headline).dynamicTypeSize(...DynamicTypeSize.accessibility2).accessibilityIdentifier("offline-retry")
            }
        }.accessibilityIdentifier("offline-panel")
    }
}

/// CloudChess's own Premium promotion, shown when no network ad fills.
struct HouseAdView: View {
    let index: Int, count: Int, seconds: Double
    let finish: () -> Void
    let premium: () -> Void
    @State private var started = Date()
    private let ink = Color(rgb:0x192E49)
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let left = max(0, seconds - context.date.timeIntervalSince(started))
            ZStack {
                LinearGradient(colors: [Color(rgb:0x9CC9EE), Color(rgb:0xEAF4FB)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                VStack(spacing: 22) {
                    HStack {
                        if count > 1 { Text("\(index + 1) / \(count)").font(.subheadline.weight(.semibold)).monospacedDigit().accessibilityLabel("Ad \(index + 1) of \(count)") }
                        Spacer()
                        if left > 0 {
                            ZStack {
                                Circle().stroke(ink.opacity(0.15), lineWidth: 3)
                                Circle().trim(from: 0, to: left / seconds).stroke(ink, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                                Text("\(Int(left.rounded(.up)))").font(.footnote.weight(.bold)).monospacedDigit()
                            }.frame(width: 36, height: 36).accessibilityLabel("Ad ends in \(Int(left.rounded(.up))) seconds")
                        } else {
                            Button(action: finish) {
                                Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44).background(.white.opacity(0.7), in: Circle())
                            }.accessibilityLabel("Close ad").accessibilityIdentifier("house-ad-close")
                        }
                    }.padding(.horizontal, 24).padding(.top, 16)
                    Spacer()
                    Image(systemName: "cloud.fill").font(.system(size: 84, weight: .light)).foregroundStyle(.white)
                        .shadow(color: ink.opacity(0.18), radius: 16, y: 8).accessibilityHidden(true)
                    Text("CloudChess Premium").font(.largeTitle.weight(.bold)).multilineTextAlignment(.center)
                    VStack(spacing: 10) {
                        Label("Unlimited puzzles", systemImage: "infinity")
                        Label("No ads", systemImage: "play.slash")
                        Label("Play fully offline", systemImage: "airplane")
                    }.font(.title3.weight(.medium))
                    Spacer()
                    Button(action: premium) { Text("See plans").frame(maxWidth: .infinity) }
                        .buttonStyle(CloudActionStyle()).padding(.horizontal, 32).padding(.bottom, 32)
                        .accessibilityIdentifier("house-ad-premium")
                }.foregroundStyle(ink).dynamicTypeSize(...DynamicTypeSize.accessibility2)
            }
        }.onAppear { started = Date() }
            .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal).accessibilityIdentifier("house-ad")
    }
}
