import Foundation
import SwiftUI

/// One row in the list: a candidate opportunity plus how far its verification got.
struct Row: Identifiable, Equatable {
    let opportunity: YieldOpportunity
    var state: VerificationState

    var id: String { opportunity.id }

    /// Rank key. Verified/mismatched rows use the crawled figure; unverified rows
    /// fall back to the API figure so they still sort sensibly among peers.
    var sortAPY: Double {
        state.displayAPY ?? opportunity.apiAPYPercent
    }

    /// Only rows whose APY was confirmed against a live crawl count as settled.
    var isVerified: Bool {
        if case .verified = state { return true }
        return false
    }
}

@MainActor
final class AppModel: ObservableObject {

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusText = "Ready"
    @Published private(set) var lastRefresh: Date?
    @Published var errorMessage: String?
    /// Defaults to **on**: the app opens showing only rows whose APY was confirmed
    /// against the live site. That is the whole point of the project, so the untrusted
    /// rows start hidden rather than mixed in. The switch stays in the status bar and
    /// turning it off restores everything — nothing is discarded, and the status bar
    /// always reports "N of M shown".
    @Published var showOnlyVerified = true
    /// Defaults to $250K, not zero. See `visibleRows`.
    @Published var minTVL: Double = 250_000

    /// Which deposit page is currently open, if any.
    ///
    /// This lives on the model rather than in a `@State` in the view because
    /// CommandLineTools' `swiftc` has no `SwiftUIMacros` plugin, so `@State` cannot
    /// expand. `@StateObject` is a plain property wrapper and works fine — so all
    /// presentation state is held here instead.
    @Published var depositTarget: YieldOpportunity?

    /// How many vault pages to crawl at once. Moli drives a real browser per page,
    /// so this stays modest to avoid thrashing the machine.
    private let crawlConcurrency = 4

    /// Cap on how many rows we crawl, highest APY first. Verification is the
    /// expensive step; the top of the ranking is what the user actually acts on.
    private let crawlBudget = 24

    private let verifier = APYVerifier()

    /// Ranked highest APY to lowest (requirement 2), after the user's filters.
    ///
    /// The TVL floor defaults to $250K. Without it the list opens on pools of
    /// $10–20K, where the quoted APY cannot be captured at a size worth depositing —
    /// the ranking would be technically correct and practically useless. The floor is
    /// a user-visible control, not a hidden edit to the data: nothing is discarded,
    /// and setting it to "Any" restores the full list.
    var visibleRows: [Row] {
        rows
            .filter { showOnlyVerified ? $0.isVerified : true }
            .filter { $0.opportunity.tvlUSD >= minTVL }
            .sorted { $0.sortAPY > $1.sortAPY }
    }

    /// Candidates are known but no row has been confirmed yet — and the "Verified
    /// only" filter is on, so the list is legitimately empty while crawls are in
    /// flight. Worth distinguishing from "nothing loaded": with the filter defaulting
    /// on, this is the state the app opens in, every launch.
    var isAwaitingFirstVerification: Bool {
        !rows.isEmpty && visibleRows.isEmpty && isLoading
    }

    var verifiedCount: Int { rows.filter { $0.isVerified }.count }
    var mismatchCount: Int {
        rows.filter { if case .mismatch = $0.state { return true }; return false }.count
    }
    var unverifiedCount: Int {
        rows.filter { if case .unverified = $0.state { return true }; return false }.count
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        rows = []
        statusText = "Fetching stablecoin yields from Beefy…"

        do {
            let opportunities = try await BeefySource.fetchEthereumStablecoins()
            guard !opportunities.isEmpty else {
                statusText = "No stablecoin vaults returned"
                isLoading = false
                return
            }

            rows = opportunities.map { Row(opportunity: $0, state: .pending) }
            statusText = "Found \(opportunities.count) candidates — verifying the top \(min(crawlBudget, opportunities.count)) against the live site…"

            await verifyTop(count: min(crawlBudget, opportunities.count))
            lastRefresh = Date()
            statusText = summaryText()
        } catch {
            errorMessage = error.localizedDescription
            statusText = "Could not fetch yields"
        }
        isLoading = false
    }

    /// Crawl the top N candidates, a few at a time, updating the UI as each settles.
    private func verifyTop(count: Int) async {
        let targets = rows.prefix(count).map { $0.opportunity }
        let verifier = self.verifier

        await withTaskGroup(of: (String, VerificationState).self) { group in
            var next = 0
            let initial = min(crawlConcurrency, targets.count)

            for _ in 0..<initial {
                guard next < targets.count else { break }
                let opp = targets[next]
                next += 1
                markVerifying(opp.id)
                group.addTask {
                    let state = await verifier.verify(
                        id: opp.id,
                        pageURL: opp.pageURL,
                        apiPercent: opp.apiAPYPercent
                    )
                    return (opp.id, state)
                }
            }

            while let (id, state) = await group.next() {
                apply(state, to: id)
                if next < targets.count {
                    let opp = targets[next]
                    next += 1
                    markVerifying(opp.id)
                    group.addTask {
                        let state = await verifier.verify(
                            id: opp.id,
                            pageURL: opp.pageURL,
                            apiPercent: opp.apiAPYPercent
                        )
                        return (opp.id, state)
                    }
                }
            }
        }

        // Anything beyond the crawl budget stays honestly unverified.
        for i in count..<rows.count where rows[i].state == .pending {
            rows[i].state = .unverified(reason: "Not crawled (outside verification budget)")
        }
    }

    private func markVerifying(_ id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].state = .verifying
        statusText = "Verifying… \(verifiedCount) confirmed, \(unverifiedCount) unverified"
    }

    private func apply(_ state: VerificationState, to id: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].state = state
        statusText = "Verifying… \(verifiedCount) confirmed, \(unverifiedCount) unverified"
    }

    private func summaryText() -> String {
        var parts = ["\(verifiedCount) verified"]
        if mismatchCount > 0 { parts.append("\(mismatchCount) mismatched") }
        if unverifiedCount > 0 { parts.append("\(unverifiedCount) unverified") }
        let shown = visibleRows.count
        parts.append("\(shown) of \(rows.count) shown")
        return "Checked against live sites at \(Fmt.time(lastRefresh ?? Date())) — " + parts.joined(separator: ", ")
    }
}