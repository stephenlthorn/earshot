# Calendar and calls

Two optional features help Earshot know what meeting you're in and when it starts.

- **Calendar:** Earshot reads the current event, so the notes know its title, people and agenda. It also looks back at past meetings with the same people and shows a short brief as the call starts.
- **Noticing calls:** Earshot sees when a call app turns on your microphone and offers to record, or starts by itself if you allow it.

Both are off until you turn them on.

[Back to the README](../README.md)

## Calendar access

### Turning it on

1. Open **Settings > Calendar** and turn on **Use my calendar**. The **Calendar** switch in onboarding does the same.
2. macOS asks whether Earshot may access your calendars. Allow full access to events.

If you said no earlier, Settings shows "Calendar access is off" with **Open System Settings**. Allow Earshot under **Privacy & Security > Calendars**.

Earshot uses the calendars your Mac already has in the Calendar app, including Google and Microsoft 365 accounts you've added there.

### What Earshot reads

- **Only events within 12 hours of now,** before or after.
- **Only when it needs to:** when you open the menu, once a minute while nothing is recording, and again just after a recording starts.
- **It only reads.** Earshot never creates, changes or deletes events.

### Picking the current event

Earshot looks for an event happening now, or starting in the next ten minutes. It skips all-day events, cancelled events and events you've declined. When several match, it prefers, in order:

1. one with other people invited;
2. one with a video link (Zoom, Google Meet, Teams, Webex or FaceTime) in the URL, location or notes;
3. the one that starts closest to now.

When it finds one, the menu shows **Now: <title> · <profile>**, for example "Now: Acme pricing review · External". An event with nobody else invited shows the title alone. The event title also appears in the empty Title field: if you leave the title blank, it becomes the meeting title.

### What Claude sees

- **Attendee names and their company domains,** such as "Dana Lee, acme.com". Never full email addresses.
- **The agenda,** cleaned first: links become `[link]`, email addresses become their domain, and any line that mentions a passcode, password, PIN, meeting or conference ID, access code or dial-in is removed.

The event is saved in the meeting's `session.json`, with up to 50 attendees and the first 1,500 characters of the agenda. That copy keeps the attendees' email addresses and the agenda as it was, on your Mac only. Cleaning happens each time text goes to Claude.

## Profiles

Earshot sorts each meeting into a profile, then picks the mode and notes style from it.

### My domains

Your company domains are:

- the domain of your own address on the event;
- plus any domains you type in **My company domains** under **Settings > Calendar > Profiles**, for example `acme.com, acme.co.uk`. Separate them with commas or spaces. The Profiles section is greyed out until **Use my calendar** is on.

Subdomains count too: `eu.acme.com` is inside `acme.com`. Personal email domains never count as company domains: gmail.com, googlemail.com, icloud.com, me.com, mac.com, outlook.com, hotmail.com, live.com, yahoo.com, aol.com, proton.me, protonmail.com and fastmail.com.

An invited person with no email address on the event counts as outside your company. Rooms and other resources don't count as people.

### The three profiles

| Profile | When | Mode | Notes style |
|---|---|---|---|
| **External** | Someone invited is outside your domains | **External meetings**, by default Notes + Do | Sales call if the title has a sales word, otherwise General meeting |
| **Internal** | Everyone invited is inside your domains | **Internal meetings**, by default Notes | General meeting |
| **None** | No event, or nobody else invited | Your default mode | Your default style |

- **Notes + Do needs a Do target.** If no Do target is switched on, an External or Internal meeting set to Notes + Do gets Notes instead.
- **Sales words** decide the Sales call style. The defaults are demo, discovery, intro, proposal, pricing, sales, pitch, quote and consult. You can edit them in **Sales words in titles** in **Settings > Calendar**.
- **You stay in charge of the mode.** When a new event becomes current, Earshot preselects its mode. If you change it, Earshot leaves your choice alone until a different event comes up. When the event is over and you haven't changed the mode, Earshot puts your default mode back.
- **External meetings always show the confirm window** before anything is sent, even with **Ask before sending** off in Settings > Do. Their action items come from people outside your company. Recordings that began from a call notice get the confirm window too.

## The brief

When a call starts, the panel can show a short brief: what this meeting is about and what's still open from last time.

> **Acme pricing review: second call after the pilot**
> - Ashley sent the pilot scope on Friday.
> - They asked about volume pricing for 40 seats.
>
> Open from last time
> - Dana: Confirm who signs off (Acme pilot kickoff, 8 Oct)

### When you get one

Earshot writes a brief only when all of these hold:

- the mode isn't Record;
- the event has an agenda, or there's at least one related past meeting;
- **Show a short brief when a meeting starts** is on in **Settings > Calendar**. It is on by default, and it only works while **Use my calendar** is on.

It starts in the background when the recording starts, so it never delays the recording. Claude gets up to 60 seconds to write it. If it fails, or the recording stops before it's ready, you see no brief and nothing else changes.

The brief shows in the panel, so you only see it with **Show the panel during calls** on. For External meetings it starts folded, so it isn't on show if you share your screen. Click **Brief** to open it.

### What it contains

- a headline;
- up to four short points;
- open loops: up to eight action items from earlier meetings with the same people, with who owes them and which meeting they came from.

It uses the **Brief and Ask** model in **Settings > Claude** (claude-sonnet-5-5 by default), at low effort. It's saved as `brief.json` in the meeting folder.

### How past meetings are matched

Earshot looks at up to five meetings from the last 180 days, newest first. A past meeting counts as related when:

- **it shared an attendee** with this one, other than you, matched by email address; or
- **for meetings recorded without a calendar event,** the names in its notes match an attendee's full name, or the title you typed for it is the same; or
- **its title matches,** but only when this event has nobody else invited and the title isn't a generic one. Generic titles are: weekly sync, standup, stand up, 1:1, one on one, catch up, check in, intro call, sync, meeting, call, team meeting and all hands.

### The brief in your notes

After the call, the notes check each open loop against what was said. The notes page has a **Still open from before** section for anything that wasn't settled. This works even if no brief was written, as long as the meeting has a calendar event: Earshot then takes the action items from the related meetings directly, with no extra call to Claude.

### Who said what

Earshot records two tracks, your microphone and the call, so it can't tell remote voices apart. The notes name a remote speaker only when the transcript makes it clear:

- they introduced themselves ("Hi, it's Dana from Acme");
- someone addressed them by name;
- only one person from outside your company was invited.

Otherwise the notes say "Them" or use the company name. They won't guess.

## Noticing calls

### Turning it on

Turn on **Notice when a call app uses the microphone** in **Settings > Calendar > Noticing calls**, or **Notice calls** in onboarding. It needs no extra permission: Earshot reads macOS's list of which apps are using audio, and checks again every 3 seconds.

### Which apps count

- **Call apps:** Zoom, Microsoft Teams, Webex, Slack, Discord, FaceTime, Skype, Tuple and Loom.
- **Browsers,** for calls in a tab: Chrome, Safari, Firefox, Edge, Arc, Brave, Vivaldi and Opera.

Earshot matches these apps by their bundle ID. Other apps don't count, even when they use the microphone.

### When Earshot asks

Earshot offers to record when all of these are true:

- one of those apps starts using a real microphone: your default input, or a built-in, USB or Bluetooth mic, not a virtual or aggregate device;
- Earshot isn't already recording;
- it hasn't asked about the same app in the last 10 minutes.

You get a notification: "**Zoom is using your microphone. Record this call?**" with **Record** and **Not now**. The app name is the one macOS shows, so it can read "zoom.us" or "Google Chrome".

If notifications are off for Earshot, the menu bar icon shows a badge and the same choice appears in the menu instead.

The question goes stale after 10 minutes. Pressing **Record** on an older notification does nothing.

Pressing **Record** counts as a recording Earshot started for the call. It can stop when the call ends, and its consent banner stays until you dismiss it.

### Starting automatically

Turn on **Start recording automatically** to skip the question. It's off by default, and it's limited:

- It only applies to dedicated call apps, or to a browser when your current calendar event has a video link. Anything else still asks.
- You can turn it on only while **Notice when a call app uses the microphone** is on and Earshot's notifications are allowed or **Show the panel during calls** is on, so you always see that a recording started.

When it starts, and Earshot's notifications are allowed, a notification says "**Recording your Zoom call**", with **Stop**. The recording uses the current event's profile, and its notes always go through the confirm window before anything is sent.

### Stopping when the call ends

Earshot only stops recordings that began from a call: ones it started automatically, and ones you started with **Record** on its call question. **A recording you started with the Record button in the menu is never stopped automatically.**

Earshot decides the call has ended when the call app hasn't used the microphone for 45 seconds, and one of these is also true:

- the app has quit;
- the app has stopped playing sound too;
- the calendar event has ended.

Then, with **Stop when the call ends** on (the default), the recording stops. With it off, Earshot asks and waits for your answer.

If the microphone stops but none of those is true, for example because you muted yourself while others keep talking, Earshot asks after 45 seconds: "**The call seems to have ended. Stop recording?**" with **Stop** and **Keep recording**. If you don't answer and the microphone stays unused for 5 minutes, it stops on its own, whatever **Stop when the call ends** says. **Keep recording** keeps it going: Earshot doesn't ask again or stop on its own until you unmute, or the call ends (the app quits, its sound stops or the event is over).

## The consent line

Recording laws differ from place to place, and many require everyone in the conversation to agree. Tell people you're recording. You are responsible for recording lawfully.

When a recording starts, and **Remind me to tell everyone I'm recording** is on (the default), the panel shows a "Let everyone know" banner with **Copy line**. The default line is:

> Quick heads-up: I'm recording this call so an AI assistant can transcribe it and take notes. I'll share the notes afterwards.

With screen reading on, it adds: "It also reads what's shared on screen."

- Paste it into the call chat, or read it out.
- The banner stays for 2 minutes. For a recording that began from a call, it stays until you dismiss it.
- If **Show the panel during calls** is off, a notification shows the reminder instead: "Recording. Let everyone know.", with **Copy consent line**.
- You can edit the line in **Line to copy**, or turn the reminder off, in **Settings > Calendar > Consent**. A blank line uses the default.

## Turning it off

- Switch off **Use my calendar** and Earshot stops reading events. Meetings already recorded keep the event details they saved.
- Switch off **Notice when a call app uses the microphone** and Earshot stops watching for call apps.
- You can also remove calendar access in **System Settings > Privacy & Security > Calendars**.

Without the calendar, there's no brief and no profile, and Earshot uses your default mode. Everything else works as before.
