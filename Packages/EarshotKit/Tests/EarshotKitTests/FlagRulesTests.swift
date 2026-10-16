import Foundation
import Testing
@testable import EarshotKit

struct FlagRulesTests {
    @Test func aPhraseOnItsOwnIsAFlag() {
        for text in ["Flag that.", "flag this", "Mark that!", "Mark this?", "  FLAG THAT  ", "Flag that"] {
            #expect(FlagRules.isVoiceFlag(text), "\(text)")
        }
    }

    @Test func aPhraseAtTheStartOrEndOfASentenceIsAFlag() {
        #expect(FlagRules.isVoiceFlag("Flag that, the budget number is wrong."))
        #expect(FlagRules.isVoiceFlag("Okay, flag that."))
        #expect(FlagRules.isVoiceFlag("We agreed on Friday. Mark this. Then we move on."))
        #expect(FlagRules.isVoiceFlag("The price went up again, let's flag this"))
        #expect(FlagRules.isVoiceFlag("Good point; mark that; next item"))
        #expect(FlagRules.isVoiceFlag("Line one\nflag this\nline three"))
    }

    @Test func earshotFlagWorksAnywhere() {
        #expect(FlagRules.isVoiceFlag("Earshot, flag"))
        #expect(FlagRules.isVoiceFlag("so earshot flag the part about pricing please"))
        #expect(FlagRules.isVoiceFlag("Ear shot, flag."))
        #expect(FlagRules.isVoiceFlag("EARSHOT FLAG THAT"))
        #expect(FlagRules.isVoiceFlag("Earshot. Flag."))  // a pause after the name can become a full stop
    }

    @Test func thePhraseInsideASentenceIsNotAFlag() {
        #expect(!FlagRules.isVoiceFlag("the flag that waves"))
        #expect(!FlagRules.isVoiceFlag("Can you flag that for me tomorrow?"))
        #expect(!FlagRules.isVoiceFlag("We should mark this as done and move on"))
        #expect(!FlagRules.isVoiceFlag("He hit the mark that year"))
    }

    @Test func aColleagueCalledMarkIsNotAFlag() {
        for text in ["Mark, that was close.", "Mark, this is Sam.", "Mark, that is right.", "Tell Mark that.",
                     "Did you ask Mark this?", "Okay. Mark, this one is yours."] {
            #expect(!FlagRules.isVoiceFlag(text), "\(text)")
        }
        // The verb still works, at the start of a sentence or lower case at its end.
        #expect(FlagRules.isVoiceFlag("Mark that, it matters."))
        #expect(FlagRules.isVoiceFlag("Okay, mark that."))
    }

    @Test func aCommaBetweenTheTwoWordsBreaksThePhrase() {
        #expect(!FlagRules.isVoiceFlag("Flag, that is the one we wave."))
        #expect(!FlagRules.isVoiceFlag("They raised the flag, that."))
        #expect(FlagRules.isVoiceFlag("Flag that, the budget number is wrong."))  // a comma after the phrase is fine
    }

    @Test func aQuestionToSomeoneElseIsNotAFlag() {
        #expect(!FlagRules.isVoiceFlag("Can you flag that?"))
        #expect(!FlagRules.isVoiceFlag("Should we mark this?"))
        #expect(FlagRules.isVoiceFlag("Flag that?"))  // the phrase on its own still counts
    }

    @Test func nearMissesAreNotFlags() {
        for text in ["", "   ", "flag", "Flag.", "that", "Flag that's what they wave.", "Flagging that.", "the flag",
                     "flag the thing", "Earshot is great", "mark these", "Earshot flagged it"] {
            #expect(!FlagRules.isVoiceFlag(text), "\(text)")
        }
    }

    @Test func aFlagWithinTenSecondsOfAnotherIsIgnored() {
        let existing = [Flag(offset: 100, source: .hotkey)]
        #expect(!FlagRules.shouldAdd(at: 100, existing: existing))
        #expect(!FlagRules.shouldAdd(at: 109.9, existing: existing))
        #expect(!FlagRules.shouldAdd(at: 90.1, existing: existing))
        #expect(FlagRules.shouldAdd(at: 110, existing: existing))
        #expect(FlagRules.shouldAdd(at: 90, existing: existing))
        #expect(FlagRules.shouldAdd(at: 0, existing: []))
    }

    @Test func theDebounceCoversEveryFlagNotOnlyTheLastOne() {
        let existing = [Flag(offset: 300, source: .voice), Flag(offset: 50, source: .panel)]
        #expect(!FlagRules.shouldAdd(at: 55, existing: existing))
        #expect(FlagRules.shouldAdd(at: 200, existing: existing))
    }

    @Test func thereAreAtMostOneHundredFlags() {
        let ninetyNine = (0..<99).map { Flag(offset: Double($0) * 20, source: .hotkey) }
        #expect(FlagRules.shouldAdd(at: 99 * 20, existing: ninetyNine))
        let hundred = ninetyNine + [Flag(offset: 99 * 20, source: .hotkey)]
        #expect(hundred.count == Flag.maxCount)
        #expect(!FlagRules.shouldAdd(at: 100 * 20, existing: hundred))
    }

    @Test func anOffsetThatIsNotARealTimeIsNeverAdded() {
        #expect(!FlagRules.shouldAdd(at: .nan, existing: []))
        #expect(!FlagRules.shouldAdd(at: .infinity, existing: []))
        #expect(!FlagRules.shouldAdd(at: -1, existing: []))
    }
}
