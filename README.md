# PushUpsMac

PushUpsMac counts your push-ups as you do them. Put an iPhone on the floor beside you, and the Mac uses it as a camera
through Continuity Camera. The app finds your body in every frame and counts each rep, then times it and checks it for
two things:

- **Full range of motion:** down to the floor, and back up to straight arms.
- **A straight back:** no sagging or piked hips.

The Mac says each rep's number out loud as it's counted. When the set ends, it goes into your history in the
**Progress** tab, and its recording opens as a clip you can watch back with the count.

PushUpsMac also opens a clip you filmed earlier and counts the push-ups in it the same way.

The body pose comes from Apple's Vision framework, on the Mac itself. Nothing is uploaded, and there's no account or
API key.

<!-- Screenshot: a live set in progress: the camera's picture with the overlay on the body, the reps in the sidebar, and the panel's charts under the picture -->

## What you need

- **A Mac with macOS 27 or newer.**
- **Xcode 27**, to build the app.
- **A camera:** an iPhone used through Continuity Camera, or any other camera the Mac sees (the built-in camera, or
  one plugged in).
- **Floor space** for a push-up, and for the phone beside you, far enough away to see all of you.

## Build and run

1. Clone the repository:

   ```bash
   git clone https://github.com/nainajnahO/PushUpsMac.git
   ```

2. Open `PushUpsMac.xcodeproj` in Xcode.
3. Pick your own team: select the **PushUpsMac** target, then **Signing & Capabilities**, then **Team**. The project
   is set to its author's team, and Xcode signs the app for your Mac with yours.
4. Choose **Product › Run** (⌘R).

To build from Terminal instead, pass your team ID:

```bash
xcodebuild -project PushUpsMac.xcodeproj -scheme PushUpsMac -destination 'platform=macOS' DEVELOPMENT_TEAM=<your team ID> build
```

The first time you turn on the camera, macOS asks whether PushUpsMac may use it.

## Film yourself

The app sees you from one side and measures the side nearer the camera, so the set-up matters more than anything
else:

- **Landscape:** turn the iPhone on its side.
- **On the floor:** stand the phone on the floor, at your level, not on a table looking down.
- **Side-on:** put it beside you, opposite your middle, facing your side. Facing left or right both work.
- **Your whole body in frame:** hands to feet, from the top of the push-up to the bottom. Move the phone back until
  all of you fits, with some room to spare.

<!-- Screenshot: the camera's picture of a good set-up: side-on at floor level, the whole body in frame, the overlay on the near arm and the body line -->

The default settings were set on six clips of one person filmed this way. If your camera stands elsewhere, or the
grades don't match what you did, see the [User guide](#user-guide).

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
4. **End the set.** Click **Camera** again. The set goes into your history in the **Progress** tab. If it was
   recorded, the recording opens as a clip, with the count and grades it had live.

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
  - your shoulder's height, with the lines a rep must reach at the bottom and at the top;
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
  those clips are found again the next time you open them. Nothing is written into or beside your clips.

## Privacy

Everything stays on your Mac:

- **Vision runs on the Mac.** Nothing is uploaded; the app has no network access at all.
- **No account or sign-in.**
- **The camera is used only while Camera is on.** Its picture goes nowhere but the screen and, with Record each set on,
  the recording in Movies › PushUpsMac.
- **The app opens only the clips you give it.** It writes only to its own folder and Movies › PushUpsMac, and moves
  a deleted set's recording to the Trash.

This repository holds no video either. The tests use stick figures (Vision's joints for each frame of six clips) and
counts in `golden/`. The clips themselves stay on the Mac they were filmed for.

## User guide

Every setting the app has, where to find it, what it does, its default, and when to change it.

| Setting | Where | Default | Kept after you quit |
|---|---|---|---|
| Say each rep's number | Sidebar › Live | On | No |
| Add a cue for a short rep or a bent back | Sidebar › Live | On | No |
| Record each set | Sidebar › Live | On | No |
| Down height | Sidebar › Settings | 0.60 | No |
| Up | Sidebar › Settings | 90% | No |
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

These decide what counts as a full rep and a straight back, and which time a rep shows. A change counts the open clip,
or the live set so far, again at once. Sets already in your history keep the grades they were counted with.

**Restore Defaults** puts all four back.

**Down height:**
- **What it does:** how close your shoulder must come to your hand at the bottom, in arm lengths above the wrist.
  An arm length is measured with the arm straight in your plank, so the top of a push-up reads about 1. A rep whose
  shoulder doesn't get this low is "not to the floor".
- **Default:** 0.60. The full reps it was set on bottomed out at 0.34–0.58, and a half rep at 0.63.
- **Range:** 0.30 to 0.90.
- **When to change it:** raise it if reps you went all the way down on are marked "not to the floor". Lower it to
  ask for a deeper push-up.

**Up:**
- **What it does:** how far back up a rep must come at the top, as a share of your plank height. A rep that stops
  short of it is "not back up".
- **Default:** 90%.
- **Range:** 70% to 100%.
- **When to change it:** lower it if reps you locked out are marked "not back up". Raise it to ask for straighter
  arms at the top.

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
- **What it does:** off, the overlay draws only what's measured: your near arm, and the body line in place of your
  torso and leg. On, it draws both sides of the body, with the body line over them.
- **Default:** off.
- **When to change it:** turn it on to check that Vision has found your body correctly, if the count seems off.

### Progress

**Group by** (the switch at the top of the Progress tab's list):
- **What it does:** gathers your sets by day, week, month or year. Each row opens to the next shorter period, down to
  days, and a day to its sets.
- **Default:** Day.
- **When to change it:** pick Week, Month or Year to look back over a longer time.

## For developers

| Path | What |
|---|---|
| `App/` | The SwiftUI app |
| `Engine/` | The `PushUpsEngine` Swift package (video, pose, analysis, tests) and the `pushups-cli` tool |
| `golden/` | Vision's keypoints for each test clip and the counts they're held to, for the tests (no video) |

To run the engine's tests:

```bash
cd Engine && swift test
```

The tests that read the clips themselves are skipped without them, since the clips aren't in the repository.
[PLAN.md](PLAN.md) has the plan and the decisions behind it, and the [issues](../../issues) track the work.

## Credits and licence

Inspired by the [push-ups demo](https://github.com/jeremyipark/vision-demos/tree/main/push_ups) in
[vision-demos](https://github.com/jeremyipark/vision-demos) by Jeremy Park, licensed under Apache-2.0. The method
(counting reps from the shoulder's height above the wrist, timing each rep's phases, and grading its range of motion
and body line) comes from it. PushUpsMac is licensed under Apache-2.0 as well (see [LICENSE](LICENSE)).
