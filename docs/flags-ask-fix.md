# Flags, ask and fix

Three ways to make the notes say what you need:

- **Flags** mark a moment during the call that the notes must cover.
- **Ask** answers questions about a meeting after it's over.
- **Fix** tells Earshot what's wrong with the notes, and rewrites them.

Earshot also learns from the changes you make, so later notes need fewer fixes.

[Back to the README](../README.md)

## Flags

A flag says "this part matters". The notes always cover a flagged moment, and the notes page lists each one with its time.

### Three ways to flag

| How | What to do | Needs |
|---|---|---|
| **Hotkey** | Press ⌃⌥⌘F (Control-Option-Command-F) from any app | Nothing. It works while Earshot is recording, in any mode |
| **Button** | Click the flag button in the panel's header | The panel open |
| **Voice** | Say "flag that", "flag this", "mark that" or "mark this", or "Earshot, flag" | The live assistant on, in Notes or Notes + Do |

**Voice flags** only listen to your own microphone, not the other people on the call. The phrase has to be said on its own, or at the start or end of a sentence: "That's the number we need. Flag that." counts, while "we should flag that with legal" in the middle of a sentence doesn't. A question such as "Can you flag that?" doesn't count either. "Earshot, flag" counts anywhere in a sentence.

A flag within 10 seconds of another one counts once, however you made it.

**When a flag lands,** the panel shows "Flagged at 12:31" for a few seconds, and a hotkey flag also plays a short "Tink" sound.

You can switch both off in **Settings > Live**, under Flags: **Flag a moment with ⌃⌥⌘F** and **Flag by saying "flag that"**. If another app already uses ⌃⌥⌘F, Settings says "Earshot couldn't register ⌃⌥⌘F" and the other two ways still work.

A meeting can hold up to 100 flags.

### How the notes use flags

- Earshot gives Claude 30 seconds of transcript either side of each flag, and asks for a short note on what happened there.
- The notes have a **Flagged moments** section, with each time as mm:ss, for example "18:42 Dana agreed to the 40-seat price". If nothing was said near a flag, Claude is told so.
- On the notes page, flags also appear on the timeline.
- With [screen reading](screen-reading.md) on, the text on screen near each flag is picked first, so "this number here" makes sense in the notes.
- During the call, the live assistant also sees the times of flags in the stretch of transcript it is reading.

## Ask

Ask answers questions about one meeting, from its transcript, notes and flags.

1. Click the waveform icon in the menu bar.
2. Find the meeting under **Recent** and click **Ask…**.
3. Type a question in **Ask a question**, for example "What did Acme say about the pilot dates?", and click **Ask**.

Answers point to the moment in the call with a time like `[18:42]`, so you can check what was really said.

- **Ask…** shows for every meeting with a transcript, once recording has stopped. A Record-only meeting has no transcript, so it has no **Ask…** button.
- Ask uses the quick model, claude-sonnet-5-5 by default, at medium effort. Change the model in **Settings > Claude**, under **Brief and Ask**. The effort can't be changed.
- Your questions and answers are saved in `qa.json` in the meeting folder.
- For very long meetings, Ask reads up to the first 300,000 characters of transcript, which is many hours of talk. Claude is told when the rest was cut off.

To ask about many meetings at once, such as "what did Mike say about pricing last week?", use Claude Code or Claude Desktop with Earshot's MCP server. See [AI apps](ai-apps.md).

## Fix

Fix rewrites the notes from your instruction.

1. Open **Ask…** on the meeting.
2. Click **Fix the notes** at the top of the window.
3. Type what's wrong in **What should change?** and click **Fix**. For example:
   - "Ashley owns the proposal, not Dana."
   - "The due date for the proposal is Friday, not Monday."
   - "Add an action item: send Acme the revised proposal by Friday."
   - "Keep the summary to three sentences."
4. Earshot shows what would change: items added, removed and changed, and whether the title or summary changed.
5. Click **Save** to keep the new version, or **Discard** to keep the old one.

When you save:

- the old notes are kept in the meeting folder: the first Fix keeps the original as `notes-r0.json`, the next keeps `notes-r1.json`, and so on;
- `notes.json`, `notes.md` and the notes page are rewritten;
- Claude Code and other AI apps see the corrected notes;
- your instruction is saved as a lesson for future notes, when **Learn from my edits** is on.

Fix uses the notes model, claude-opus-5-5 at medium effort by default. Both are set in **Settings > Claude** (**Notes and Fix**, **Notes effort**).

**Fix is greyed out while Earshot is still working on that meeting.** The window says "Earshot is still working on this meeting. Fix is available when it's done." Wait for the notes and any sending to finish. A meeting with no notes yet says "This meeting has no notes to fix yet."

If the notes change between your Fix and your Save, Save is refused with "The notes changed since you asked for this fix. Fix again."

**If the action items were already sent** in a Notes + Do meeting, and a Do target is on, saving offers **Send the 2 new items…** when the fix added items. It opens the normal confirm window with only those items, so you choose what goes. Items that were already sent, or started during the call, aren't sent again.

## Learning from your edits

Earshot keeps examples of the changes you make, and shows them to Claude next time. If you keep changing "Me" to "Ashley" as the owner of follow-up emails, or keep unticking "Schedule a follow-up call", later notes start doing the same.

### What counts as an edit

In the confirm window you can tick or untick each item and edit its task, owner and due date. Earshot compares what you send with what the window first showed, and saves a lesson for each difference:

| What you did | What Earshot learns |
|---|---|
| Unticked an item Claude suggested | You didn't want that kind of item sent |
| Ticked an item Claude didn't suggest | You wanted it sent anyway |
| Changed a task, owner or due date | The before and after, as an example |
| Saved a Fix | Your instruction, in your words |

Lessons are saved only when you click **Send** in the confirm window, or **Save** in Fix. Nothing is learned when you click **Skip**, close the window, send with **Ask before sending** off, or send from the command line.

Edits in the confirm window also correct the notes. When you send with an edited task, owner or due date, Earshot saves a new version of the notes, the same way Fix does.

### How lessons are used

- New notes get up to 8 lessons, and the live assistant up to 6: the newest lessons from the same notes style first, then the newest from other styles.
- They are examples, not rules. Claude uses them as a guide to what you usually want.
- Like everything from a meeting, the old wording inside a lesson is treated as information, never as an instruction.

### Seeing and resetting what Earshot learned

Lessons live in `~/Library/Application Support/Earshot/lessons.json`. Earshot keeps the newest 200, with each text cut to 200 characters.

In **Settings > Storage**, under **What Earshot learned**, you'll find:

- how many lessons Earshot has;
- **Learn from my edits**, on by default. Switch it off to stop saving new lessons and to stop sending saved ones to Claude;
- **Forget what Earshot learned…**, which deletes all lessons after you confirm. Your meetings and notes stay as they are.
