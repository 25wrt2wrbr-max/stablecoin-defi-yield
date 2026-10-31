import Foundation

/// Fetches candidate stablecoin yield opportunities from Beefy's own API.
///
/// The user chose the cross-check model: this API value is only ever a *candidate*.
/// Nothing here is displayed as fact until `Verifier` has confirmed it against a live
/// crawl of the protocol's app page.
///
/// Scope is **single-sided** positions only — one stablecoin in, yield out. LP and
/// other multi-asset pools are excluded (see the filter in `fetchEthereumStablecoins`).
enum BeefySource {

    /// Stablecoins we consider "parking" money. Matched case-insensitively against a
    /// vault's `assets`.
    static let stablecoins: Set<String> = [
        "USDC", "USDC.E", "USDT", "USDT0", "DAI", "USDS", "SDAI", "SUSDS",
        "USDE", "SUSDE", "FRAX", "FRXUSD", "LUSD", "GHO", "PYUSD", "RLUSD",
        "CRVUSD", "SCRVUSD", "USR", "SAVUSD", "USD1", "USDG", "USDX", "FXUSD",
        "MIM", "OUSD", "USDF", "PMUSD", "VUSD", "USG", "YB", "SUSD", "ALUSD"
    ]

    struct RawVault: Decodable {
        let id: String
        let name: String
        let chain: String
        let status: String
        let platformId: String?
        let assets: [String]?
        let tokenAddress: String?
        let earnContractAddress: String?
        let addLiquidityUrl: String?
        /// Present on every vault in the API today, but optional here so a response
        /// without it degrades to "no flags known" rather than failing the whole fetch.
        let risks: RiskFlags?
    }

    enum SourceError: LocalizedError {
        case http(Int, String)
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let url): return "HTTP \(code) from \(url)"
            case .decoding(let detail): return "Could not parse response: \(detail)"
            }
        }
    }

    private static func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw SourceError.http(0, urlString)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("StablecoinYieldFinder/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceError.http(http.statusCode, urlString)
        }
        return data
    }

    /// Fetch and filter to Ethereum stablecoin vaults, ranked highest APY first.
    static func fetchEthereumStablecoins() async throws -> [YieldOpportunity] {
        async let vaultsData = get("https://api.beefy.finance/vaults")
        async let apyData = get("https://api.beefy.finance/apy/breakdown")
        async let tvlData = get("https://api.beefy.finance/tvl")

        let vaults = try await vaultsData
        let apys = try await apyData
        let tvls = try await tvlData

        let rawVaults: [RawVault]
        do {
            rawVaults = try JSONDecoder().decode([RawVault].self, from: vaults)
        } catch {
            throw SourceError.decoding("vaults: \(error.localizedDescription)")
        }

        // APY breakdown: { vaultId: { totalApy: 0.3464, ... } }
        let apyMap: [String: [String: Any]] =
            (try? JSONSerialization.jsonObject(with: apys)) as? [String: [String: Any]] ?? [:]

        // TVL is keyed by chain ID as a string; Ethereum is "1".
        let tvlByChain: [String: [String: Double]] =
            (try? JSONSerialization.jsonObject(with: tvls)) as? [String: [String: Double]] ?? [:]
        let ethTVL = tvlByChain["1"] ?? [:]

        var out: [YieldOpportunity] = []
        for v in rawVaults {
            guard v.chain == "ethereum", v.status == "active" else { continue }

            let assets = v.assets ?? []

            // Single-sided only. The user's requirement: one stablecoin must be
            // enough to earn the APY shown. An LP vault (convex, stakedao, curve,
            // fx) quotes a yield on a *basket* — capturing it means supplying every
            // asset in the pool, and the quote is a blend of the legs, so those
            // rows are out of scope here regardless of how good the number looks.
            //
            // Beefy's `assets` array lists exactly the tokens a deposit requires, so
            // "exactly one asset, and it is a stablecoin" is the precise test — not a
            // proxy. On today's Ethereum data it coincides with the single-sided
            // strategy ids (`single`, `single-lp`, `lendingNoBorrow`), but asset count
            // is the semantic fact and is what this keys on.
            //
            // Measured 2026-09-26: narrows 63 candidates to 16 (the other 47 are
            // multi-lp: 23 stakedao, 16 convex, 5 curve, 3 fx).
            guard assets.count == 1,
                  let sole = assets.first,
                  stablecoins.contains(sole.uppercased())
            else { continue }

            guard let entry = apyMap[v.id],
                  let total = entry["totalApy"] as? Double, total > 0 else { continue }

            guard let pageURL = URL(string: "https://app.beefy.com/vault/\(v.id)") else { continue }

            // Prefer the protocol's own add-liquidity page; fall back to the vault page.
            let depositString = v.addLiquidityUrl ?? "https://app.beefy.com/vault/\(v.id)"
            guard let depositURL = URL(string: depositString) else { continue }

            out.append(YieldOpportunity(
                id: v.id,
                name: v.name,
                platform: v.platformId ?? "unknown",
                assets: assets,
                chain: v.chain,
                apiAPY: total,
                tvlUSD: ethTVL[v.id] ?? 0,
                pageURL: pageURL,
                depositURL: depositURL,
                risk: v.risks ?? RiskFlags()
            ))
        }

        // Rank highest yield to lowest (requirement 2), before verification refines it.
        out.sort { $0.apiAPY > $1.apiAPY }
        return out
    }
}