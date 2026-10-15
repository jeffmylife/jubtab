import Cocoa

/// Fork: ranking for the Jump search. Matching reuses the switcher's own `SearchTestable.tierMatch` (exact >
/// prefix > word prefix > substring > acronym > typo-tolerant), so both searches agree on what a good match is.
enum JumpSearch {
    struct Results {
        let items: [JumpItem]
        /// Character ranges of each item's title to bold, by item id.
        let spans: [String: [Range<Int>]]
    }

    /// A title match beats a keyword match of the same quality; a keyword-only match still counts.
    private static let keywordPenalty = 50
    /// Each past pick of an item adds this much, up to `pickCap` picks: enough to reorder matches of one tier,
    /// never enough to lift an item into a better tier (tiers are 200 apart).
    private static let pickBoost = 4
    private static let pickCap = 10
    private static let picksKey = "jumpPicks"
    private static let emptyQueryOrder: [JumpItem.Section] = [.servers, .windows, .workspaces, .tabs]
    private static let emptyQueryWindowLimit = 12

    static func results(_ items: [JumpItem], _ query: String) -> Results {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Results(items: browse(items), spans: [:]) }
        let picks = UserDefaults.standard.dictionary(forKey: picksKey) as? [String: Int] ?? [:]
        var scored = [(item: JumpItem, score: Int)]()
        var spans = [String: [Range<Int>]]()
        for item in items {
            let title = SearchTestable.tierMatch(query: trimmed, text: item.title)
            let keyword = item.keywords.isEmpty ? nil : SearchTestable.tierMatch(query: trimmed, text: item.keywords)
            let titleScore = title?.score ?? -1
            let keywordScore = (keyword?.score ?? -1) - keywordPenalty
            let best = max(titleScore, keywordScore)
            guard best >= 0 else { continue }
            if let title, titleScore >= keywordScore { spans[item.id] = title.subspans.isEmpty ? [title.span] : title.subspans }
            scored.append((item, best + min(picks[item.id] ?? 0, pickCap) * pickBoost))
        }
        let ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : ($0.item.recency ?? .distantPast) > ($1.item.recency ?? .distantPast)
        }
        return Results(items: ranked.map(\.item), spans: spans)
    }

    static func recordPick(_ item: JumpItem) {
        var picks = UserDefaults.standard.dictionary(forKey: picksKey) as? [String: Int] ?? [:]
        picks[item.id, default: 0] += 1
        UserDefaults.standard.set(picks, forKey: picksKey)
    }

    /// Nothing typed yet: everything, grouped, with only the most recent windows.
    private static func browse(_ items: [JumpItem]) -> [JumpItem] {
        emptyQueryOrder.flatMap { section -> [JumpItem] in
            let group = items.filter { $0.section == section }
            return section == .windows ? Array(group.prefix(emptyQueryWindowLimit)) : group
        }
    }
}
