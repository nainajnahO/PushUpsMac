# PushUpsMac user guide

How to count a live set, open a clip and follow your progress, and what every setting does. To build the app and set
up the camera, start with the [README](../README.md#get-started).

- [Count a live set](#count-a-live-set)
- [Open a clip](#open-a-clip)
- [The Progress tab](#the-progress-tab)
- [Where things are kept](#where-things-are-kept)
- [Every setting](#every-setting)

## Count a live set

1. **Turn on the camera.** In the **Workout** tab, click **Camera** in the toolbar. A **Camera** menu appears beside
   it. Pick your iPhone there the first time; the app remembers it. (With no camera picked yet, it starts on the Mac's
   own camera.)
2. **Get into position.** The picture shows what the camera sees, with your near arm and body line drawn on it. The
   window's subtitle shows the camera's size and frame rate, and how many frames a second Vision is posing.
3. **Do your push-ups.** As each rep is counted:
   - the Mac says its number, and what fell short if anything did ("not to the floor", "not back up", "hips low",
     "hips high");
   - it's added to **Reps** in the sidebar, with its time and its grade;
   - the panel under the picture adds it to its charts.

   While the set is being recorded, the **Camera** button is red and pulses.
4. **End the set.** Click **Camera** again. If it counted any reps, the set goes into your history in the
   **Progress** tab. If it was recorded, the recording opens as a clip, with the count and grades it had live.

While a set is going:

- **Changing a setting** in the sidebar counts the set so far again with it.
- **Picking another camera** in the toolbar switches to it, and the set goes on.
- **If the camera goes away** (the iPhone loses its connection, say), the picture says "Waiting for" the camera, and
  the set goes on once it's back.
- **Opening a clip** ends the set. It's still kept and recorded, but the clip opens in place of its recording.

## Open a clip

Open a clip of push-ups in any of these ways:

- **File › Open…** (⌘O), or **Open…** in the toolbar.
- Drop a movie on the window.
- In the Finder, **Open With › PushUpsMac**.

Film it as you would for a live set. The first time a clip is opened, the subtitle says "Finding the body…" while
Vision goes through every frame. That takes a while: on an M1 Pro, a 4K clip at 60 fps takes about twice as long as it
plays. The poses are kept, so the same clip opens at once after that, also after you quit the app; if the clip
changes, it's posed again. A set recorded by the app has its poses inside the movie, so it opens at once too.

Then the clip plays from the start:

- **The overlay** follows the clip as it plays, and as you scrub.
- **Click a rep** in the sidebar to jump to where it starts.
- **The panel** under the clip shows the whole set:
  - the push-ups, their average push-up time, and how many had full range and a straight back;
  - your elbow's angle, with the lines a rep must reach at the bottom and at the top;
  - your body line, with the limits past which the hips count as low or high;
  - each rep's push-up time.

  A line on each chart follows the frame on screen.

<!-- Screenshot: a clip open, with the overlay, a rep selected in the sidebar, and the panel's charts with the playhead line -->

Each rep in the sidebar shows:

- **Its push-up time.**
- **When it starts**, how long it took to go down, and how long it paused at the bottom.
- **Its range:** full, or what fell short ("not to the floor", "not back up").
- **Its back:** straight, or "hips low" or "hips high" ("unseen" if the body line couldn't be measured).

## The Progress tab

Click **Progress** in the toolbar to see every set you've counted live. (Clips you open aren't added.)

**The list** on the left gathers your sets by day, week, month or year; pick which with the switch at its top. Each
row shows its push-ups, its sets, and the share of reps with full range and a straight back. Open a row to see the
shorter periods in it, and a day to see its sets.

**The dashboard** on the right shows:

- **The figures:** this week's push-ups against last week's, days in a row with a set, the shares of full range and
  straight back over the last seven days, your biggest set, and all your push-ups.
- **Day by Day:** push-ups per day, form, and push-up time. Form and push-up time are averaged over the seven days up
  to each day.
- **Within a Set:** form and push-up time by rep number, so you can see how your first reps compare with your last.

Hover over a chart to see its values.

<!-- Screenshot: the Progress tab, the list grouped by week with a week opened, beside the dashboard -->

**Correct the history:**

- **See a set's reps:** select the set, and its reps show in a table.
- **Remove a rep counted by mistake:** select it, then press Delete, or Control-click it and choose **Remove Rep**. A
  set keeps at least one rep; to remove them all, delete the set.
- **Delete a set:** swipe it left, select it and press Delete, or Control-click it and choose **Delete**. Its
  recording goes to the Trash.
- **Merge two sets into one,** for a set you stopped and started again: drag one set onto the other, or select both,
  Control-click, and choose **Merge Sets**.

**Edit › Undo** takes back any of these, including bringing a deleted set's recording back from the Trash. A deleted
set goes for good when you next open the app.

<!-- Screenshot: one set selected in the Progress tab, its reps in the table -->

## Where things are kept

- **Recordings:** in your **Movies › PushUpsMac** folder, one movie per set, named for when it started, such as
  "Push-ups 2026-11-07 at 18.05.12.mov". It has the video, without sound, and the poses the set was counted with. Any
  player opens it as a plain movie.
- **Your history:** inside the app's own folder in your Library (`~/Library/Containers/nainajnahO.PushUpsMac`).
- **The poses of clips you open:** in the app's caches, in the same folder, up to 200 MB. Deleting them is safe:
  Vision goes through those clips again the next time you open them. Nothing is written into or beside your clips.

## Every setting

Every setting the app has, where to find it, what it does, its default, and when to change it.

| Setting | Where | Default | Kept after you quit |
|---|---|---|---|
| Say each rep's number | Sidebar › Live | On | No |
| Add a cue for a short rep or a bent back | Sidebar › Live | On | No |
| Record each set | Sidebar › Live | On | No |
| Back tolerance | Sidebar › Settings | ±14° | No |
| Push-up time | Sidebar › Settings | Moving | No |
| Camera | Toolbar, while the camera is on | The Mac's own camera, until you pick one | Yes |
| Show Whole Skeleton | View menu (⇧⌘K) | Off | No |
| Group by | Progress tab, top of the list | Day | Yes |

<!-- Screenshot: the sidebar's Live and Settings sections, with their defaults -->

### Live

These are for counting from the camera.

**Say each rep's number:**
- **What it does:** the Mac says each rep's number out loud as it's counted. If a rep is counted while the last
  number is still being said, the new one cuts it short, so the count is never late.
- **Default:** on.
- **When to change it:** turn it off for a silent set.

**Add a cue for a short rep or a bent back:**
- **What it does:** after the number, the Mac says what fell short, as the rep list says it: "not to the floor", "not
  back up", "hips low", "hips high". A rep that passed gets only its number.
- **Default:** on. It works only while Say each rep's number is on.
- **When to change it:** turn it off to hear only the count.

**Record each set:**
- **What it does:** saves the camera's video, without sound, and the poses to Movies › PushUpsMac. The set opens as a
  clip once the camera is off.
- **Default:** on. You can't change it while the camera is on.
- **When to change it:** turn it off to keep no video. The set still goes into your history, counted live, but
  there's no clip to watch it back.

### Settings

These decide what counts as a straight back, and which time a rep shows. A change counts the open clip, or the live
set so far, again at once. Sets already in your history keep the grades they were counted with.

**Restore Defaults** puts both back.

What counts as a rep and a full one isn't a setting. It's read off your elbow, as an angle, so it doesn't change with
how far you are from the camera or how long your arms are:

- **A rep** starts when your elbow bends past 130° and ends when it straightens past 140° again.
- **"Not to the floor":** the elbow didn't bend to 115° or less at the bottom.
- **"Not back up":** it didn't straighten past 140° at the top, usually because the set ended halfway up.

The numbers are lower than the 90° and 180° you might expect: Vision reads a straight arm as about 150–170°, and the
arm it reads is the one farther from the camera, which it partly guesses behind your body. On the test clips, that arm
followed half reps where the nearer one didn't.

**Back tolerance:**
- **What it does:** how far your body line may bend, hips low or high, from the start of the descent to the top. The
  body line runs from your shoulder to your ankle, and the angle is your hip's off it. Past the tolerance, the rep is
  "hips low" or "hips high", and on the overlay the body line turns red and dashed, labelled at the hip.
- **Default:** ±14°.
- **Range:** ±5° to ±30°.
- **When to change it:** raise it if reps with a straight back are marked bent. That can happen with a camera that
  isn't quite side-on, or baggy clothes. Lower it to be stricter.

**Push-up time:**
- **What it does:** which part of a rep its push-up time measures.
  - **Moving:** from leaving the bottom to the top, leaving out a pause on the floor.
  - **Whole way up:** from the deepest point to the top, with the pause included.

  It changes the times in the sidebar, the panel, and the Progress tab.
- **Default:** Moving.
- **When to change it:** pick Whole way up if you pause at the bottom on purpose and want the pause counted.

### The camera

**Camera:**
- **What it does:** the camera to count from, picked in the toolbar while the camera is on. A set stays on the camera
  it started on until you pick another. If that camera goes away, the set waits for it to come back.
- **Default:** the camera you picked last. Before you've picked one, it's the Mac's own camera, or the first camera
  there is.
- **When to change it:** pick your iPhone the first time, and whenever you want to count from another camera.

### Overlay

**Show Whole Skeleton** (**View › Show Whole Skeleton**, ⇧⌘K):
- **What it does:** off, the overlay draws your near arm, and the body line in place of your torso and leg. The count
  reads the elbow of the arm farther from the camera, which the overlay doesn't draw. On, it draws both sides of the
  body, with the body line over them.
- **Default:** off.
- **When to change it:** turn it on to check that Vision has found your body correctly, if the count seems off.

### Progress

**Group by** (the switch at the top of the Progress tab's list):
- **What it does:** gathers your sets by day, week, month or year. Each row opens to the next shorter period, down to
  days, and a day to its sets.
- **Default:** Day.
- **When to change it:** pick Week, Month or Year to look back over a longer time.
