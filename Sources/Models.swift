import Foundation

// MARK: - Verification

/// How much trust we have earned for a row's APY figure.
///
/// This is the heart of the app. A number is only `.verified` when the protocol's
/// own endpoint and a live crawl of the protocol's own app page agree. Anything
/// else is labelled honestly rather than shown as if it were confirmed.
enum VerificationState: Equatable {
    /// Queued, crawl not started yet.
    case pending
    /// Crawl running right now.
    case verifying
    /// API value and crawled value agree within tolerance.
    case verified(api: Double, crawled: Double)
    /// They disagree. `crawled` is shown (site is ground truth), `api` is surfaced too.
    case mismatch(api: Double, crawled: Double)
    /// Crawl could not produce a number. `reason` is shown to the user.
    case unverified(reason: String)

    /// The APY we should display, and where it came from.
    var displayAPY: Double? {
        switch self {
        case .verified(_, let crawled): return crawled
        case .mismatch(_, let crawled): return crawled
        default: return nil
        }
    }

    var isSettled: Bool {
        switch self {
        case .pending, .verifying: return false
        default: return true
        }
    }
}

// MARK: - Opportunity

/// Risk flags reported by the protocol's own API. Surfaced rather than hidden:
/// the highest yields in DeFi are almost always the riskiest positions, and an app
/// that shows an 8% number in a $2 pool without the caveat is misleading.
///
/// Note on `curated`: only ~30% of Ethereum vaults carry it, so `curated == false`
/// is the norm rather than a warning. It is recorded and shown as a positive
/// attribute when present, never counted as a defect — otherwise nearly every row
/// would be flagged and the flags would become noise the user learns to ignore.
/// Decoded straight from the API's `risks` object via `Decodable`, so the same JSON
/// parse that reads the vault covers the flags too. Every field is optional and
/// defaults to `false`: the API emits the full set today, but treating a missing key
/// as "no warning" is the only safe reading — inventing a warning from absence would
/// be its own kind of dishonesty.
struct RiskFlags: Equatable, Decodable {
    var complex = false          // leveraged / multi-step strategy
    var notAudited = false       // strategy contracts unaudited
    var notBattleTested = false  // new, no track record
    var notCorrelated = false    // assets can diverge — real impermanent-loss exposure
    var notTimelocked = false    // upgrades take effect without delay
    var notVerified = false      // contract source unverified on-chain
    var synthAsset = false       // synthetic asset exposure
    var curated = false          // positive signal: manually reviewed by Beefy

    /// True only for flags that are genuine warnings. `curated` is excluded by design.
    var hasWarnings: Bool {
        complex || notAudited || notBattleTested || notCorrelated
            || notTimelocked || notVerified || synthAsset
    }

    /// Short human-readable warnings, most serious first.
    var labels: [String] {
        var out: [String] = []
        if notAudited { out.append("unaudited") }
        if notVerified { out.append("unverified contract") }
        if synthAsset { out.append("synthetic asset") }
        if complex { out.append("leveraged") }
        if notCorrelated { out.append("assets can diverge") }
        if notBattleTested { out.append("new") }
        if notTimelocked { out.append("no timelock") }
        return out
    }

    init() {}

    /// Tolerant decoding, deliberately.
    ///
    /// Beefy's live API is not uniform: 4,005 of 4,042 vaults carry `risks` as an
    /// object, but 37 carry it as a legacy *array* of tags (`["COMPLEXITY_LOW",
    /// "IL_NONE", ...]`) — all of them `eol` vaults on retired chains. Those vaults
    /// are filtered out downstream, but decoding happens first, so a strict decoder
    /// would throw and take the entire fetch down with it.
    ///
    /// Non-object shapes therefore degrade to "no flags known" rather than failing.
    /// That is safe in this direction only: it can never invent a warning that the
    /// protocol did not declare.
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        complex = (try? c.decodeIfPresent(Bool.self, forKey: .complex)) ?? false
        notAudited = (try? c.decodeIfPresent(Bool.self, forKey: .notAudited)) ?? false
        notBattleTested = (try? c.decodeIfPresent(Bool.self, forKey: .notBattleTested)) ?? false
        notCorrelated = (try? c.decodeIfPresent(Bool.self, forKey: .notCorrelated)) ?? false
        notTimelocked = (try? c.decodeIfPresent(Bool.self, forKey: .notTimelocked)) ?? false
        notVerified = (try? c.decodeIfPresent(Bool.self, forKey: .notVerified)) ?? false
        synthAsset = (try? c.decodeIfPresent(Bool.self, forKey: .synthAsset)) ?? false
        curated = (try? c.decodeIfPresent(Bool.self, forKey: .curated)) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case complex, curated, notAudited, notBattleTested
        case notCorrelated, notTimelocked, notVerified, synthAsset
    }
}

struct YieldOpportunity: Identifiable, Equatable {
    let id: String                 // Beefy vault id, e.g. "convex-mim"
    let name: String               // "MIM/DAI/USDC/USDT"
    let platform: String           // "convex", "stakedao", "morpho"...
    let assets: [String]           // ["MIM", "DAI", "USDC", "USDT"]
    let chain: String              // "ethereum"
    let apiAPY: Double             // fraction, e.g. 0.3464
    let tvlUSD: Double
    let pageURL: URL               // protocol's own app page (crawl target)
    let depositURL: URL            // where the user actually goes to deposit
    let risk: RiskFlags

    /// APY as a percentage number, e.g. 34.64
    var apiAPYPercent: Double { apiAPY * 100 }

    var displayName: String { name }

    /// Very small pools are the most practical red flag — you may not be able to
    /// get your money back out at the quoted rate.
    var isThinlyTraded: Bool { tvlUSD > 0 && tvlUSD < 250_000 }
}

// MARK: - Formatting helpers

enum Fmt {
    static func apy(_ percent: Double) -> String {
        String(format: "%.2f%%", percent)
    }

    static func usd(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "$%.2fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "$%.1fK", value / 1_000)
        }
        return String(format: "$%.0f", value)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}