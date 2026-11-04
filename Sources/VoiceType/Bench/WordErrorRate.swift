import Foundation

/// Reduces a transcript to the words WER compares: lowercase, punctuation
/// stripped (apostrophes dropped, hyphens/dashes/slashes split words),
/// whitespace collapsed, and numbers spelled out the way LibriSpeech references
/// read them, so a numeral in the hypothesis can match: "21" → "twenty one",
/// four-digit years 1100–2099 year-style ("1961" → "nineteen sixty one", "2005"
/// → "two thousand five", "2010" → "twenty ten"), "$5" → "five dollars", "5%"
/// → "five percent". Applied identically to reference and hypothesis.
enum TranscriptNormalizer {
    static func words(_ text: String) -> [String] {
        // "$" and "%" become tokens of their own; a comma between digits is a
        // thousands separator ("1,905"), kept as "_" so the number stays whole
        // and reads as a quantity, never a year.
        var cleaned = ""
        let chars = Array(text.lowercased())
        for (i, c) in chars.enumerated() {
            if c.isLetter || c.isNumber {
                cleaned.append(c)
            } else if c == "," && i > 0 && i + 1 < chars.count && chars[i - 1].isNumber && chars[i + 1].isNumber {
                cleaned.append("_")
            } else if c == "'" || c == "’" || c == "‘" {
                continue
            } else if c == "$" || c == "%" {
                cleaned += " \(c) "
            } else {
                cleaned.append(" ")
            }
        }

        var words: [String] = []
        var dollars = false     // the previous token was "$"
        for token in cleaned.split(separator: " ").map(String.init) {
            defer { if token != "$" { dollars = false } }
            if token == "$" { dollars = true; continue }
            if token == "%" { words.append("percent"); continue }
            let digits = token.replacingOccurrences(of: "_", with: "")
            guard digits.allSatisfy(\.isASCIIDigit), let n = Int(digits), n < 1_000_000_000 else {
                words.append(token)
                continue
            }
            let isYear = !dollars && token.count == 4 && (1100...2099).contains(n)
            words += isYear ? year(n) : spell(n)
            if dollars { words.append(n == 1 ? "dollar" : "dollars") }
        }
        return words
    }

    /// "nineteen sixty one", "nineteen hundred", "nineteen oh five", "two
    /// thousand five", "twenty ten".
    private static func year(_ n: Int) -> [String] {
        if (2000...2009).contains(n) { return spell(n) }
        let (century, rest) = (n / 100, n % 100)
        let tail = rest == 0 ? ["hundred"] : rest < 10 ? ["oh", ones[rest]] : spell(rest)
        return spell(century) + tail
    }

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                               "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                               "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// Cardinal words for 0..<1e9, without "and" (LibriSpeech style).
    private static func spell(_ n: Int) -> [String] {
        if n < 20 { return [ones[n]] }
        if n < 100 { return [tens[n / 10]] + (n % 10 == 0 ? [] : [ones[n % 10]]) }
        for (size, name) in [(1_000_000, "million"), (1_000, "thousand"), (100, "hundred")] where n >= size {
            return spell(n / size) + [name] + (n % size == 0 ? [] : spell(n % size))
        }
        return []
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// Word-level edit counts between a reference and a hypothesis (minimum
/// Levenshtein alignment over normalized words). `rate` is the usual WER:
/// (S + D + I) / reference words, so it can exceed 1.
struct WordErrorRate: Equatable, Codable {
    var substitutions: Int
    var deletions: Int
    var insertions: Int
    var referenceWords: Int

    var errors: Int { substitutions + deletions + insertions }

    /// 0 for an empty reference with an empty hypothesis; 1 if words were
    /// hallucinated over an empty reference.
    var rate: Double {
        referenceWords > 0 ? Double(errors) / Double(referenceWords) : (errors > 0 ? 1 : 0)
    }

    init(substitutions: Int, deletions: Int, insertions: Int, referenceWords: Int) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceWords = referenceWords
    }

    // JSON carries `rate` too, for readers; it's derived, so decoding ignores it.
    private enum CodingKeys: String, CodingKey { case substitutions, deletions, insertions, referenceWords, rate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(substitutions: try c.decode(Int.self, forKey: .substitutions),
                  deletions: try c.decode(Int.self, forKey: .deletions),
                  insertions: try c.decode(Int.self, forKey: .insertions),
                  referenceWords: try c.decode(Int.self, forKey: .referenceWords))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(substitutions, forKey: .substitutions)
        try c.encode(deletions, forKey: .deletions)
        try c.encode(insertions, forKey: .insertions)
        try c.encode(referenceWords, forKey: .referenceWords)
        try c.encode(rate, forKey: .rate)
    }

    static func score(reference: String, hypothesis: String) -> WordErrorRate {
        align(TranscriptNormalizer.words(reference), TranscriptNormalizer.words(hypothesis))
    }

    /// Corpus WER: edits and reference words summed, so longer clips weigh more.
    static func total(_ parts: [WordErrorRate]) -> WordErrorRate {
        parts.reduce(WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 0)) {
            WordErrorRate(substitutions: $0.substitutions + $1.substitutions,
                          deletions: $0.deletions + $1.deletions,
                          insertions: $0.insertions + $1.insertions,
                          referenceWords: $0.referenceWords + $1.referenceWords)
        }
    }

    /// Levenshtein DP over words, two rows at a time (a 10 min clip is ~2k
    /// words, so a full matrix would be millions of cells). Each cell carries
    /// its S/D/I breakdown; ties prefer the fewest total edits, then
    /// substitution over deletion over insertion.
    private static func align(_ ref: [String], _ hyp: [String]) -> WordErrorRate {
        typealias Cell = (s: Int, d: Int, i: Int)
        func cost(_ c: Cell) -> Int { c.s + c.d + c.i }

        var prev: [Cell] = (0...hyp.count).map { (0, 0, $0) }   // vs empty ref: all insertions
        for r in ref.indices {
            var row: [Cell] = [(0, r + 1, 0)]                     // vs empty hyp: all deletions
            for h in hyp.indices.map({ $0 + 1 }) {
                let diag = prev[h - 1]
                let match: Cell = ref[r] == hyp[h - 1] ? diag : (diag.s + 1, diag.d, diag.i)
                let del: Cell = (prev[h].s, prev[h].d + 1, prev[h].i)
                let ins: Cell = (row[h - 1].s, row[h - 1].d, row[h - 1].i + 1)
                var best = match
                if cost(del) < cost(best) { best = del }
                if cost(ins) < cost(best) { best = ins }
                row.append(best)
            }
            prev = row
        }
        let end = prev[prev.count - 1]
        return WordErrorRate(substitutions: end.s, deletions: end.d, insertions: end.i, referenceWords: ref.count)
    }
}
