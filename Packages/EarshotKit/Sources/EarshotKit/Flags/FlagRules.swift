import Foundation

/// When a flag counts: the spoken phrases (spec 8) and the debounce and cap shared by every way to flag.
public enum FlagRules {
    /// Said on their own or at the start or end of a sentence.
    public static let phrases: [[String]] = [["flag", "that"], ["flag", "this"], ["mark", "that"], ["mark", "this"]]
    /// Said anywhere: the name, then "flag". The recognizer sometimes hears the name as two words.
    public static let namedCommands: [[String]] = [["earshot", "flag"], ["ear", "shot", "flag"]]
    /// A flag this close to an existing one is a repeat.
    public static let debounce: Double = 10

    /// True when a final transcript line is a spoken flag. "the flag that waves" is not one, and neither is a
    /// colleague called Mark ("Mark, this is Sam.", "Tell Mark that.") or a question to someone else ("Can you flag
    /// that?").
    public static func isVoiceFlag(_ text: String) -> Bool {
        let sentences = sentences(text)
        let all = sentences.flatMap { $0.words.map(\.key) }
        if namedCommands.contains(where: { contains(all, $0) }) { return true }
        return sentences.contains(where: hasPhrase)
    }

    /// True when a flag at `offset` should be saved: a real time, not within `debounce` seconds of another flag,
    /// and fewer than `Flag.maxCount` flags so far.
    public static func shouldAdd(at offset: Double, existing: [Flag]) -> Bool {
        guard offset.isFinite, offset >= 0, existing.count < Flag.maxCount else { return false }
        return !existing.contains { abs($0.offset - offset) < debounce }
    }

    struct Word {
        /// Lower case, without accents: what the phrases are matched against.
        var key: String
        /// As heard, so "Mark" the name can be told from "mark" the verb.
        var original: String
        /// A comma came straight after the word.
        var commaAfter = false
    }

    struct Sentence {
        var words: [Word] = []
        var isQuestion = false
    }

    /// A phrase as the first two or the last two words of the sentence, with no comma between them. At the end,
    /// a capitalised "Mark" mid-sentence is a name, and a longer question is asked of someone else.
    private static func hasPhrase(_ sentence: Sentence) -> Bool {
        let words = sentence.words
        guard words.count >= 2 else { return false }
        func matches(_ at: Int) -> Bool {
            !words[at].commaAfter && phrases.contains([words[at].key, words[at + 1].key])
        }
        if matches(0) { return true }
        let last = words.count - 2
        guard last > 0, matches(last), !sentence.isQuestion else { return false }
        return !(words[last].key == "mark" && words[last].original.first?.isUppercase == true)
    }

    /// Sentences end at `. ! ? ; :` and newlines. Words keep their apostrophes, so "that's" never reads as "that".
    static func sentences(_ text: String) -> [Sentence] {
        var sentences: [Sentence] = []
        var sentence = Sentence()
        var word = ""
        func endWord() {
            guard !word.isEmpty else { return }
            let key = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            sentence.words.append(Word(key: key, original: word))
            word = ""
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "\u{2019}" {
                word.append(character)
                continue
            }
            endWord()
            if character == ",", !sentence.words.isEmpty { sentence.words[sentence.words.count - 1].commaAfter = true }
            if ".!?;:\n".contains(character) {
                sentence.isQuestion = character == "?"
                sentences.append(sentence)
                sentence = Sentence()
            }
        }
        endWord()
        sentences.append(sentence)
        return sentences.filter { !$0.words.isEmpty }
    }

    private static func contains(_ words: [String], _ run: [String]) -> Bool {
        guard words.count >= run.count else { return false }
        return (0...(words.count - run.count)).contains { Array(words[$0..<($0 + run.count)]) == run }
    }
}
