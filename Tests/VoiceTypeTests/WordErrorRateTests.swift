import XCTest
@testable import VoiceType

/// Tests for the bench's transcript normalization and word error rate: pure
/// text in, counts out.
final class WordErrorRateTests: XCTestCase {

    // MARK: - Normalization

    func testNormalizationLowercasesStripsPunctuationAndCollapsesWhitespace() {
        XCTAssertEqual(TranscriptNormalizer.words("  And so, my fellow   Americans!\n Ask not…"),
                       ["and", "so", "my", "fellow", "americans", "ask", "not"])
    }

    func testApostrophesAreDroppedSoContractionsMatchEitherWay() {
        XCTAssertEqual(TranscriptNormalizer.words("DON'T"), TranscriptNormalizer.words("don’t"))
        XCTAssertEqual(TranscriptNormalizer.words("Don't"), ["dont"])
    }

    func testHyphensAndDashesSplitWords() {
        XCTAssertEqual(TranscriptNormalizer.words("twenty-one—well/maybe"), ["twenty", "one", "well", "maybe"])
    }

    func testDigitsAreSpelledOutLikeTheReferences() {
        XCTAssertEqual(TranscriptNormalizer.words("0 7 13 21 100 1,905"),
                       ["zero", "seven", "thirteen", "twenty", "one", "one", "hundred",
                        "one", "thousand", "nine", "hundred", "five"])
    }

    func testFourDigitYearsReadYearStyle() {
        let w = TranscriptNormalizer.words
        XCTAssertEqual(w("1961"), ["nineteen", "sixty", "one"])
        XCTAssertEqual(w("1900"), ["nineteen", "hundred"])
        XCTAssertEqual(w("1905"), ["nineteen", "oh", "five"])
        XCTAssertEqual(w("2005"), ["two", "thousand", "five"])
        XCTAssertEqual(w("2000"), ["two", "thousand"])
        XCTAssertEqual(w("2010"), ["twenty", "ten"])
        XCTAssertEqual(w("1100"), ["eleven", "hundred"])
    }

    func testNumbersOutsideTheYearRangeOrWithSeparatorsStayCardinal() {
        let w = TranscriptNormalizer.words
        XCTAssertEqual(w("1099"), ["one", "thousand", "ninety", "nine"])
        XCTAssertEqual(w("2100"), ["two", "thousand", "one", "hundred"])
        XCTAssertEqual(w("1,961"), ["one", "thousand", "nine", "hundred", "sixty", "one"])
    }

    func testDollarsAndPercentKeepTheirUnitWords() {
        let w = TranscriptNormalizer.words
        XCTAssertEqual(w("$5"), ["five", "dollars"])
        XCTAssertEqual(w("$1"), ["one", "dollar"])
        XCTAssertEqual(w("$1,500 total"), ["one", "thousand", "five", "hundred", "dollars", "total"])
        XCTAssertEqual(w("$1999"), ["one", "thousand", "nine", "hundred", "ninety", "nine", "dollars"],
                       "A dollar amount is never a year")
        XCTAssertEqual(w("up 5% today"), ["up", "five", "percent", "today"])
        XCTAssertEqual(w("costs $ much"), ["costs", "much"], "A stray $ is dropped")
    }

    func testEmptyAndPunctuationOnlyTextHasNoWords() {
        XCTAssertEqual(TranscriptNormalizer.words(""), [])
        XCTAssertEqual(TranscriptNormalizer.words(" ... — ! "), [])
    }

    // MARK: - Scoring

    func testIdenticalTextAfterNormalizationScoresZero() {
        let wer = WordErrorRate.score(
            reference: "AND SO MY FELLOW AMERICANS ASK NOT",
            hypothesis: " And so, my fellow Americans, ask not.")
        XCTAssertEqual(wer, WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 7))
        XCTAssertEqual(wer.rate, 0)
    }

    func testCountsSubstitutionsDeletionsAndInsertions() {
        // ref:  the cat sat on the mat
        // hyp:  a the bat sat on mat   → "a" added (I), cat→bat (S), second "the" dropped (D)
        let wer = WordErrorRate.score(reference: "the cat sat on the mat", hypothesis: "a the bat sat on mat")
        XCTAssertEqual(wer, WordErrorRate(substitutions: 1, deletions: 1, insertions: 1, referenceWords: 6))
        XCTAssertEqual(wer.errors, 3)
        XCTAssertEqual(wer.rate, 0.5, accuracy: 1e-9)
    }

    func testEmptyHypothesisIsAllDeletions() {
        let wer = WordErrorRate.score(reference: "one two three", hypothesis: "")
        XCTAssertEqual(wer, WordErrorRate(substitutions: 0, deletions: 3, insertions: 0, referenceWords: 3))
        XCTAssertEqual(wer.rate, 1)
    }

    func testInsertionsCanPushTheRateAboveOne() {
        let wer = WordErrorRate.score(reference: "hi", hypothesis: "oh hi there friend")
        XCTAssertEqual(wer.insertions, 3)
        XCTAssertEqual(wer.rate, 3, accuracy: 1e-9)
    }

    func testEmptyReferenceRateIsZeroOnlyWhenHypothesisIsEmptyToo() {
        XCTAssertEqual(WordErrorRate.score(reference: "", hypothesis: "").rate, 0)
        XCTAssertEqual(WordErrorRate.score(reference: "", hypothesis: "noise").rate, 1)
    }

    func testCorpusRateSumsEditsOverSumOfReferenceWords() {
        // Not the mean of per-clip rates: a long clip weighs more than a short one.
        let a = WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 2)    // 0.5
        let b = WordErrorRate(substitutions: 0, deletions: 0, insertions: 0, referenceWords: 8)    // 0
        let total = WordErrorRate.total([a, b])
        XCTAssertEqual(total, WordErrorRate(substitutions: 1, deletions: 0, insertions: 0, referenceWords: 10))
        XCTAssertEqual(total.rate, 0.1, accuracy: 1e-9)
    }
}
