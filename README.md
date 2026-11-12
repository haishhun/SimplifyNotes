# SimplifyNotes — handwritten notes for iPad

A native iPad note-taking app for university students: Apple Pencil handwriting (PencilKit),
Subjects → Notebooks → Pages organisation, paper templates, PDF annotation, and combined
multi-notebook PDF export. Swift, SwiftUI, UIKit (where needed), PencilKit, PDFKit, Vision,
SwiftData + FileManager. No web views or cross-platform frameworks.

## Installation

SimplifyNotes isn't on the App Store yet, so you install it from source with Xcode.
It takes about 10 minutes the first time.

### What you need

| Item | Details |
| --- | --- |
| Mac | Running a macOS version that supports Xcode 27.2 |
| Xcode | 27.2 or later (free from the Mac App Store) |
| iPad | iPadOS 27.2 or later; Apple Pencil recommended |
| Apple Account | Any Apple Account works; a paid Apple Developer Program membership is optional (see below) |
| Cable | USB-C or Lightning cable to connect the iPad (only for the first install) |

### 1. Get the code

Clone the repository (or download it as a ZIP from GitHub and unzip it):

```sh
git clone https://github.com/haishhun/SimplifyNotes.git
cd SimplifyNotes
```

Then open the `.xcodeproj` file in that folder. Double-click it, or run `open *.xcodeproj`.

### 2. Set up signing (one time)

Apps on a real iPad must be signed with your Apple Account.

1. In Xcode, open **Xcode → Settings → Accounts**, click **+**, and sign in with your Apple Account.
2. In the project navigator, select the project, then the **MyApp** target, then the **Signing & Capabilities** tab.
3. Tick **Automatically manage signing** and choose your account under **Team**.
4. Change **Bundle Identifier** to something unique to you, for example `com.yourname.SimplifyNotes`.
   The bundle identifier in the repository is already registered to the original developer,
   so Xcode can't use it with your account.

### 3. Prepare your iPad (one time)

1. Connect the iPad to your Mac with a cable, unlock it, and tap **Trust** if asked.
2. Turn on **Developer Mode**: on the iPad, open **Settings → Privacy & Security → Developer Mode**,
   switch it on, and restart when asked. (The option appears after the iPad has been connected to Xcode once.)

### 4. Install and run

1. In Xcode's toolbar, make sure the **MyApp** scheme is selected and choose your iPad as the run destination.
2. Press **⌘R** (Product → Run). Xcode builds the app, installs it, and opens it on your iPad.
3. The first time, iPadOS may refuse to open an app from an unknown developer. On the iPad, open
   **Settings → General → VPN & Device Management**, tap your Apple Development certificate, then tap **Trust**.
   Press ⌘R again.

After the first install the app stays on your iPad like any other app. You can unplug the cable.
To install over Wi‑Fi later, enable **Connect via network** for the iPad in **Window → Devices and Simulators**.

### Free account vs. paid membership

- **Free Apple Account:** the app works normally, but its signature **expires after 7 days**. After that it
  won't open until you run it from Xcode again (step 4). Your notes are kept.
- **Apple Developer Program ($99/year):** the signature lasts a year, and you can share builds through TestFlight.

### Trying it without an iPad

Choose an iPad simulator as the run destination (for example **iPad Pro 13-inch (M5)**) and press ⌘R.
On the simulator you draw with the mouse or trackpad.

Add the launch argument `-uiTesting` (Product → Scheme → Edit Scheme → Run → Arguments) to start with an
empty, temporary library each launch. The UI tests use this, and it's handy for demos.

### Troubleshooting

| Problem | Fix |
| --- | --- |
| "Failed Registering Bundle Identifier" | Change the bundle identifier to a unique value (step 2.4). |
| "No profiles were found" | Make sure a Team is selected and **Automatically manage signing** is on. |
| iPad shows "Untrusted Developer" | Trust the certificate under Settings → General → VPN & Device Management. |
| iPad isn't listed in Xcode | Unlock it, reconnect the cable, tap **Trust**, and check that Developer Mode is on. |
| App stopped opening after a week | Free-account signature expired; run it from Xcode again. |

> **Note:** SimplifyNotes is designed for iPad. iPhone is currently enabled for testing only, and its
> layout isn't finished.

### Technical details

| Item | Version |
| --- | --- |
| Xcode | 27.2 |
| Swift | 6.4 toolchain (target uses Swift 5 language mode, `MainActor` default isolation) |
| Deployment target | iPadOS 27.2 |

## Testing

- **Run everything:** ⌘U in Xcode (scheme **MyApp** runs both bundles).
- **Unit tests** (`InkwellTests`, Swift Testing + XCTest for performance) cover:
  - notebook management;
  - page operations (add, delete, duplicate, reorder, move between notebooks, copy/paste, template changes);
  - persistence and crash recovery (atomic writes, `.bak` fallback, relaunch);
  - autosave debounce and max-delay;
  - PDF import, and export (ordering, page selection, ranges, combining notebooks, paper sizes, original PDF content);
  - shape recognition, lasso selection, and rendering.
- **UI tests** (`InkwellUITests`, XCUIAutomation) cover:
  - create subject → create notebook → draw → undo;
  - add and duplicate pages, then multi-select delete in the page overview;
  - tool switching and changing a page template;
  - combined export → preview → share.

Last run: **69 / 69 passing** on the iPad Pro 13-inch (M5) simulator, iOS 27.2.

## Architecture

```
MyApp/
  App/            Entry point, dependency container (AppEnvironment), root view
  Core/           Value types: PageStyle (templates), PageElement (text/image/link), errors, logging
  DesignSystem/   Theme tokens, shared components (swatches, paper preview, floating chrome)
  Data/
    Models/       SwiftData models: Subject, Notebook, Page, AudioRecording, TemplatePreset
    Persistence/  ModelContainer creation + damaged-store recovery
    FileStorage/  PageContentStoring protocol + FilePageContentStore (ink, elements, assets, PDFs, audio)
    Repositories/ LibraryRepository — all notebook/page business logic
  Services/
    Drawing/      Tool settings, ShapeRecognizer, stroke utilities (lasso, transform, recolor)
    Rendering/    PageBackgroundRenderer (templates), PageRenderer (composite page)
    PDF/          PDFImportService, PDFExportService, PageRangeParser
    Thumbnail/    Two-level thumbnail cache with a concurrency limiter
    Search/       Vision handwriting recognition, SwiftData search
    Audio/        Recording and playback
  Features/
    Dashboard, Subjects, Notebooks, NotebookEditor (Canvas/, Toolbar/, Sheets/),
    PageManagement, PDFImport, PDFExport, Search, Settings
  Utilities/      Colour hex, geometry and polygon math
```

**MVVM.** Views are thin. The editor (`NotebookEditorViewModel`) and the export composer
(`ExportComposerViewModel`) each have an `@Observable` view model. Business rules live in
`LibraryRepository`, which unit tests exercise directly.

**Dependency injection.** `AppEnvironment` builds the container, store, repository and services
once, and injects them through the SwiftUI environment. Tests construct the same types with an
in-memory container and a temporary directory.

### Handwriting engine

- `PageCanvasController` is a UIKit view that hosts a zoomable `PKCanvasView` subclass, so
  PencilKit re-renders ink crisply at every zoom level.
  - Beneath the ink sits a `CATiledLayer` paper/PDF underlay. Only visible tiles are drawn, at the
    current level of detail, so PDFs stay vector-sharp.
  - Text boxes, images and links sit in the same underlay; a selection overlay sits on top.
- The SwiftUI bridge's `updateUIView` is empty. Strokes never cause SwiftUI updates; the view
  model only receives "content changed" callbacks.
- **Tools:**
  - Ballpoint = `.monoline`, Fountain = `.fountainPen`, Brush = `.pen`, Pencil = `.pencil`, Highlighter = `.marker`.
  - Stroke and pixel erasers, each with a width.
  - Lasso: select, move, resize, rotate, copy, cut, duplicate, recolor, convert to text.
  - Shapes, text boxes (with a math-symbol palette), images (Photos, Files, paste, document scanner, crop), internal page links, ruler.
- **Moving or transforming a lasso selection** renders the selection once into a preview image
  and hides it from the canvas. The drawing is updated once when the drag ends, not on every frame.
- **Undo:** each page has its own `UndoManager`, and the last 6 pages are kept in memory, so
  flipping between pages keeps history. Undo/redo also works with a two-finger tap (undo),
  a three-finger tap (redo) and ⌘Z / ⇧⌘Z. Shape snapping and lasso edits register undo steps.
- **Pencil:**
  - Double-tap and squeeze follow the system preference, or an in-app override.
  - Palm rejection comes from PencilKit.
  - "Automatic" input lets fingers draw unless the system's *Only Draw with Apple Pencil* is on;
    with that on, fingers scroll and zoom.
- **Shape correction:** with the Shapes tool, or by drawing and holding at the end of a stroke,
  lines, arrows, circles/ellipses, rectangles and triangles snap into clean shapes.

### Storage & reliability

- SwiftData stores only metadata. All attributes have defaults and all relationships are optional,
  so `cloudKitDatabase: .automatic` can be enabled later without migrating the schema.
- Ink, elements, images, PDFs and audio are files behind `PageContentStoring`, keyed by page ID.
  An iCloud implementation can replace `FilePageContentStore` without changing the editor.
- **Safe saves:**
  - A serial queue keeps writes in order; reads wait for pending writes.
  - Each write keeps the previous version as `.bak`, then writes atomically (temp file + rename).
  - If a file is corrupt or missing, loading falls back to the backup and tells the user.
- **Autosave:** about 0.8 s after a pause, and never more than 4 s while writing continuously.
  Pending work is also flushed on page switch, page overview, closing the editor, and when the app
  goes to the background (inside a background task).
- Metadata is saved immediately after every repository operation.
- If the database is damaged, it is moved aside (never deleted) and a new one is created.
- PDFs are reference-counted across pages, so duplicates and pastes share one file. Unused image
  assets are garbage-collected at launch.

### PDF

- **Import:** the PDF is copied into app storage, so the original is never modified; the app
  annotates the copy. Page geometry and text are read off the main thread, and password-protected
  or damaged files are rejected with a clear message. PDF pages can be inserted anywhere in a
  notebook, then reordered or deleted like any page.
- **Export:**
  - Build a queue from any number of notebooks, by tapping thumbnails, typing ranges ("1-3, 5, 8-") or adding all.
  - Reorder or remove items, then choose page size, orientation, whether to include backgrounds, and ink quality.
  - The PDF is generated in the background with progress and cancellation, previewed with PDFKit, and shared with `ShareLink` (Files, AirDrop, Mail…).
- **Each exported page contains:**
  - the template (optional);
  - the original PDF page, kept as vector;
  - images and text, kept as real, searchable text;
  - ink, rendered at 2–4× resolution;
  - clickable internal links.

### Performance design

- Tiled rendering, so only visible regions are drawn and zooming doesn't re-render whole pages.
- Thumbnails are rendered off the main thread, at most 2 at a time, at utility priority.
  They're cached in memory (64 MB limit) and on disk, keyed by content version so edits invalidate them.
- Images are downsampled with ImageIO and decoded off the main thread.
- Drawing data is serialised on the storage queue, not the main thread.
- Handwriting recognition runs 3 s after you stop writing, never during a stroke.
- Grids are lazy; pages are loaded on demand, with a 6-page content cache in the editor.

## Performance testing on real iPad hardware

Simulator timings are not representative, so treat the `PerformanceTests` numbers as relative
baselines only.

1. **Profile on device.** Use an older supported iPad and an M-series iPad Pro, with the Release
   configuration (*Product → Profile*).
2. **Inking latency:**
   - Instruments *Animation Hitches* + *Time Profiler* while writing quickly across a full page,
     including at 3× zoom.
   - Target: no hitches during strokes and no main-thread work over 4 ms per frame.
3. **Large notebooks:**
   - Import a 300–500 page lecture PDF and add ~3,000 strokes to a few pages
     (`PerformanceTests` uses the same synthetic density).
   - Measure notebook open time, page flip time, overview scroll hitches and memory (*Allocations*,
     *VM Tracker*). Targets: open < 500 ms, flip < 100 ms, steady memory < 300 MB.
4. **Export:** 100 mixed pages with *Time Profiler* and *Allocations*. Peak memory should stay flat
   per page (each page is wrapped in an autorelease pool), and the UI should stay responsive.
5. **Thermal and battery:** write for 20 minutes with handwriting indexing on; check *Energy Log*.
6. **Baselines:** record `PerformanceTests` baselines per device in Xcode and fail on regressions.

## Known limitations

- **Password-protected PDFs** are rejected; remove the password elsewhere and re-import.
- **Exported ink is raster.** PencilKit doesn't expose vector paths that reproduce textured inks, so
  ink is rendered at high resolution (up to 4×). Text boxes and original PDF content stay vector.
- **Handwriting recognition** uses Vision. Accuracy depends on the language and handwriting, and
  mathematical notation is recognised as plain text, not LaTeX.
- **Pages are shown one at a time** (zoom and pan inside a page, flip with the page bar or sidebar),
  not as one continuous vertical scroll.
- **iCloud sync** isn't enabled yet; the storage layer and schema are designed for it (see above).
- **Document scanning** needs a real device camera; it's hidden on the simulator.
- **Apple Pencil hardware** behaviour (pressure, tilt, double-tap, squeeze, palm rejection) can only
  be verified on a real device. The simulator tests use finger input.
