import Foundation

/// Port of Misaki's `apply_stress` / `stress_weight` (misaki/en.py). Stress
/// levels follow the Python semantics:
///   * `nil`   — leave unchanged
///   * `< -1`  — strip every stress mark
///   * `-1`, or `0`/`-0.5` when a primary mark exists — demote primary to
///     secondary (existing secondaries are removed first)
///   * `0`/`0.5`/`1` on an unstressed word — prepend a secondary mark,
///     repositioned before the first vowel
///   * `>= 1` with only secondary marks — promote secondary to primary
///   * `> 1` on an unstressed word — prepend a primary mark before the
///     first vowel
enum MisakiStress {
    static let primary: Character = "ˈ"
    static let secondary: Character = "ˌ"
    static let vowels = Set("AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ")
    static let consonants = Set("bdfhjklmnpstvwzðŋɡɹɾʃʒʤʧθ")
    private static let diphthongs = Set("AIOQWYʤʧ")

    static func apply(_ ps: String, _ stress: Double?) -> String {
        guard let stress else { return ps }
        let hasPrimary = ps.contains(primary)
        let hasSecondary = ps.contains(secondary)
        if stress < -1 {
            return ps.filter { $0 != primary && $0 != secondary }
        }
        if stress == -1 || ((stress == 0 || stress == -0.5) && hasPrimary) {
            return String(
                ps.filter { $0 != secondary }.map { $0 == primary ? secondary : $0 })
        }
        if (stress == 0 || stress == 0.5 || stress == 1), !hasPrimary, !hasSecondary {
            guard ps.contains(where: { vowels.contains($0) }) else { return ps }
            return restress(String(secondary) + ps)
        }
        if stress >= 1, !hasPrimary, hasSecondary {
            return String(ps.map { $0 == secondary ? primary : $0 })
        }
        if stress > 1, !hasPrimary, !hasSecondary {
            guard ps.contains(where: { vowels.contains($0) }) else { return ps }
            return restress(String(primary) + ps)
        }
        return ps
    }

    /// Move each stress mark to just before the next vowel (Misaki `restress`).
    private static func restress(_ ps: String) -> String {
        let chars = Array(ps)
        var keyed: [(Double, Character)] = []
        keyed.reserveCapacity(chars.count)
        for (i, ch) in chars.enumerated() {
            if ch == primary || ch == secondary {
                guard
                    let j = (i..<chars.count).first(where: { vowels.contains(chars[$0]) })
                else {
                    keyed.append((Double(i), ch))
                    continue
                }
                keyed.append((Double(j) - 0.5, ch))
            } else {
                keyed.append((Double(i), ch))
            }
        }
        return String(keyed.sorted { $0.0 < $1.0 }.map(\.1))
    }

    /// Misaki `stress_weight`: diphthong shorthands weigh double.
    static func weight(_ ps: String) -> Int {
        ps.reduce(0) { $0 + (diphthongs.contains($1) ? 2 : 1) }
    }
}
