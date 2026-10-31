import SwiftUI

// MARK: - Verification badge

/// Makes the trust state legible at a glance. The user should never have to guess
/// whether a number in this app was actually confirmed.
struct VerificationBadge: View {
    let state: VerificationState

    var body: some View {
        switch state {
        case .pending:
            badge("Queued", systemImage: "clock", color: .secondary)
        case .verifying:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Verifying").font(.caption).foregroundStyle(.secondary)
            }
        case .verified:
            badge("Verified", systemImage: "checkmark.seal.fill", color: .green)
        case .mismatch:
            badge("Mismatch", systemImage: "exclamationmark.triangle.fill", color: .orange)
        case .unverified:
            badge("Unverified", systemImage: "questionmark.circle", color: .secondary)
        }
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
    }
}

// MARK: - Row

struct OpportunityRow: View {
    let row: Row
    let onOpen: (URL) -> Void

    private var displayAPY: String {
        if let v = row.state.displayAPY { return Fmt.apy(v) }
        // Not yet verified: show the API figure but greyed, never as if confirmed.
        return Fmt.apy(row.opportunity.apiAPYPercent)
    }

    private var apyIsProvisional: Bool {
        row.state.displayAPY == nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.opportunity.displayName)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(row.opportunity.platform.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    Text(row.opportunity.assets.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if row.opportunity.tvlUSD > 0 {
                        Text("TVL \(Fmt.usd(row.opportunity.tvlUSD))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                warningLine
                detailLine
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(displayAPY)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(apyIsProvisional ? .secondary : .primary)
                VerificationBadge(state: row.state)
            }

            Button {
                onOpen(row.opportunity.depositURL)
            } label: {
                Label("Deposit", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
    }

    /// Risk flags from the protocol's own API, plus a size warning.
    ///
    /// The size warning matters more than the flags in practice: the highest APYs on
    /// this list sit in pools of a few tens of thousands of dollars, where the quoted
    /// rate is not achievable at any size worth depositing. The single-sided filter
    /// sharpened this rather than softening it — 14 of the 16 rows are under $250K and
    /// the 7.95% headline sits in a pool holding $2. A high rate on a dust pool is
    /// technically true and practically misleading, so it is labelled.
    @ViewBuilder
    private var warningLine: some View {
        let risk = row.opportunity.risk
        let labels = risk.labels
        let thin = row.opportunity.isThinlyTraded

        if !labels.isEmpty || thin {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                if thin {
                    Text("tiny pool (\(Fmt.usd(row.opportunity.tvlUSD))) — rate unlikely to hold at size")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !labels.isEmpty {
                    Text(labels.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else if risk.curated {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("curated by the protocol")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Surfaces exactly what was compared. This is the audit trail for requirement 5.
    @ViewBuilder
    private var detailLine: some View {
        switch row.state {
        case .verified(let api, let crawled):
            Text("Site shows \(Fmt.apy(crawled)) · API \(Fmt.apy(api)) — agrees")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .mismatch(let api, let crawled):
            Text("Site shows \(Fmt.apy(crawled)) but API says \(Fmt.apy(api)) — discrepancy, site is shown")
                .font(.caption)
                .foregroundStyle(.orange)
        case .unverified(let reason):
            Text("\(reason) · API figure \(Fmt.apy(row.opportunity.apiAPYPercent)) not confirmed")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .verifying:
            Text("Crawling \(row.opportunity.pageURL.absoluteString)…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        case .pending:
            Text("Waiting to verify")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Main content

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            headerDivider
            if let err = model.errorMessage {
                banner(err)
            }
            listOrEmpty
            statusBar
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(item: $model.depositTarget) { opp in
            DepositSheet(opportunity: opp)
        }
        .task {
            await model.refresh()
        }
    }

    private var headerDivider: some View { Divider() }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    @ViewBuilder
    private var listOrEmpty: some View {
        if model.rows.isEmpty && model.isLoading {
            VStack(spacing: 12) {
                ProgressView()
                Text("Fetching yields and crawling the live sites…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
                Text("No stablecoin opportunities loaded").foregroundStyle(.secondary)
                Button("Refresh") { Task { await model.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.isAwaitingFirstVerification {
            // "Verified only" is on by default, so this is what launch looks like until
            // the first crawl lands. Say so, rather than showing the empty-list state —
            // and offer the way to see the unconfirmed rows meanwhile.
            VStack(spacing: 10) {
                ProgressView()
                Text("Verifying the top candidates against the live sites...")
                    .foregroundStyle(.secondary)
                Text("\(model.unverifiedCount + model.rows.filter { $0.state == .pending || $0.state == .verifying }.count) rows pending — none confirmed yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Show all rows (including unverified)") {
                    model.showOnlyVerified = false
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.visibleRows.isEmpty {
            // Crawling finished and still nothing passed the filter — either no crawl
            // succeeded, or the TVL floor excluded everything. Both are real answers;
            // neither should render as a blank pane.
            VStack(spacing: 10) {
                Image(systemName: "eye.slash").font(.largeTitle).foregroundStyle(.secondary)
                Text(model.showOnlyVerified
                     ? "No rows were confirmed against the live site"
                     : "No rows meet the current filters")
                    .foregroundStyle(.secondary)
                Text("\(model.rows.count) candidates fetched · \(model.verifiedCount) verified, \(model.mismatchCount) mismatched, \(model.unverifiedCount) unverified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if model.showOnlyVerified {
                        Button("Show unverified rows") { model.showOnlyVerified = false }
                            .controlSize(.small)
                    }
                    if model.minTVL > 0 {
                        Button("Lower TVL floor to Any") { model.minTVL = 0 }
                            .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.visibleRows) { row in
                    OpportunityRow(row: row) { _ in
                        model.depositTarget = row.opportunity
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 10))
                }
            }
            .listStyle(.inset)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)

                Spacer()

                // 70% of candidates sit under $250K, and the whole top of the ranking
                // is dust — so the size filter is the control that matters most here.
                // Defaults to $250K (see AppModel.minTVL) rather than zero.
                Text("Min TVL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Min TVL", selection: $model.minTVL) {
                    Text("Any").tag(0.0)
                    Text("$50K").tag(50_000.0)
                    Text("$250K").tag(250_000.0)
                    Text("$1M").tag(1_000_000.0)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 92)

                Toggle("Verified only", isOn: $model.showOnlyVerified)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)

                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(model.isLoading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}