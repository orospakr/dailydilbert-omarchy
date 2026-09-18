import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Daily Dilbert strip from a local unpacked archive.
//
// One strip per calendar day, chosen deterministically: the file list is
// scanned once (find, no shell), sorted with a plain code-unit comparator,
// and indexed by a mixed hash of the local yyyy-MM-dd string. Any machine
// pointed at the same archive lands on the same strip on the same day —
// no state file, nothing to sync. A murmur-style finalizer sits on top of
// djb2 because consecutive date strings hash to consecutive djb2 values,
// which would replay the (chronologically sorted) archive in order.
Panel {
  id: root
  moduleName: "andrew.daily-dilbert"
  ipcTarget: "andrew.daily-dilbert"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by (popout
  // coordinator, open-panel dot, panel switching) has to be that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.syncToday()
    root.showToday()
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.syncToday()
    root.showToday()
    root.controller.show()
    // Set after showing: showing hands the popout coordinator over, which
    // closes whichever panel was open, and that close clears the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Omarchy 4.0.3+ hands third-party widgets a PluginBarApi facade whose
  // centerHoverRevealSuppressed is read-only; assigning it throws and aborts
  // close(), leaving the panel stuck open. Prefer the setter, fall back to the
  // old direct assignment for older shells that still inject the real Bar.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---------------------------------------------------------------- theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // -------------------------------------------------------------- archive
  readonly property string comicsDirSetting: String(setting("comicsDir", "~/.local/share/dilbert"))
  readonly property string comicsRoot: {
    var dir = comicsDirSetting
    if (dir === "~") dir = Quickshell.env("HOME")
    else if (dir.indexOf("~/") === 0) dir = Quickshell.env("HOME") + dir.substring(1)
    return dir.length > 1 && dir.charAt(dir.length - 1) === "/" ? dir.substring(0, dir.length - 1) : dir
  }

  property var comics: []
  property bool scanning: false
  property bool scanFailed: false

  // Search index, parallel to `comics`: lowercased basename stems with the
  // extension dropped and `_` turned back into spaces. Built once per scan so
  // a keystroke costs one indexOf per entry per token instead of a regex.
  // The date prefix stays in, which is what lets "1998-03" match a month.
  property var haystacks: []

  function refresh() {
    if (scanning) return
    scanning = true
    lister.running = true
  }

  function applyListing(text) {
    var lines = String(text || "").split("\n")
    var files = []
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line !== "") files.push(line)
    }
    // Code-unit sort, not localeCompare: identical ordering on every machine
    // regardless of locale, which the deterministic pick depends on.
    files.sort(function(a, b) { return a < b ? -1 : (a > b ? 1 : 0) })
    var hays = []
    for (var k = 0; k < files.length; k++)
      hays.push(root.stemOf(files[k]).replace(/_/g, " ").toLowerCase())
    root.scanFailed = files.length === 0
    root.comics = files
    root.haystacks = hays
    root.runSearch()
  }

  // ------------------------------------------------------------ selection
  //
  // todayStamp is the local calendar day; dayOffset lets the arrow keys
  // browse what the widget showed (or will show) on neighbouring days.
  property string todayStamp: Qt.formatDate(new Date(), "yyyy-MM-dd")
  property int dayOffset: 0

  function syncToday() {
    var stamp = Qt.formatDate(new Date(), "yyyy-MM-dd")
    if (stamp !== todayStamp) {
      todayStamp = stamp
      dayOffset = 0
    }
  }

  // Calendar-day arithmetic via Date(y, m, d + offset) so DST shifts can't
  // skip or repeat a day the way adding 86400000 ms would.
  readonly property var selectedDate: {
    var parts = todayStamp.split("-")
    return new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]) + dayOffset)
  }
  readonly property string selectedStamp: Qt.formatDate(selectedDate, "yyyy-MM-dd")

  function pickIndex(stamp, count) {
    var h = 5381
    for (var i = 0; i < stamp.length; i++)
      h = (Math.imul(h, 33) + stamp.charCodeAt(i)) | 0
    h ^= h >>> 16
    h = Math.imul(h, 0x85ebca6b)
    h ^= h >>> 13
    h = Math.imul(h, 0xc2b2ae35)
    h ^= h >>> 16
    return (h >>> 0) % count
  }

  // A search pick overrides the day's hashed strip until something resets it
  // (T / Enter / clicking the strip / reopening the panel / stepping days).
  property string overridePath: ""

  // Precedence: the transient search preview (only while the search is open)
  // beats a picked override, which beats the day's hashed strip. Everything
  // on display — header date, caption, image, copy — reads this one property,
  // so the preview needs no separate plumbing.
  readonly property string comicPath: previewPath !== ""
    ? previewPath
    : (overridePath !== ""
      ? overridePath
      : (comics.length > 0 ? comics[pickIndex(selectedStamp, comics.length)] : ""))

  readonly property string comicUrl: {
    if (comicPath === "") return ""
    var segments = (comicsRoot + "/" + comicPath).split("/")
    for (var i = 0; i < segments.length; i++) segments[i] = encodeURIComponent(segments[i])
    return "file://" + segments.join("/")
  }

  // Filenames are "<yyyy-mm-dd>_<keyword>_<keyword>….gif"; the date is the
  // strip's original run date, the keywords make a serviceable caption.
  // These are plain functions, not bindings, because the search result rows
  // need the same labels for paths other than the displayed one.
  function baseNameOf(path) {
    var idx = path.lastIndexOf("/")
    return idx >= 0 ? path.substring(idx + 1) : path
  }

  function stemOf(path) {
    return baseNameOf(path).replace(/\.[A-Za-z0-9]+$/, "")
  }

  function dateLabelOf(path) {
    var m = baseNameOf(path).match(/^(\d{4})-(\d{2})-(\d{2})/)
    if (!m) return ""
    var d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
    return Qt.formatDate(d, "dddd, d MMMM yyyy")
  }

  function keywordsOf(path) {
    var m = stemOf(path).match(/^\d{4}-\d{2}-\d{2}[_ ]?(.*)$/)
    if (!m || m[1] === "") return ""
    return m[1].split("_").filter(function(k) { return k.trim() !== "" }).join(" · ")
  }

  readonly property string comicBasename: baseNameOf(comicPath)
  readonly property string stripDateLabel: dateLabelOf(comicPath)
  readonly property string keywordsLabel: keywordsOf(comicPath)

  readonly property string selectionLabel: previewPath !== ""
    ? "Preview"
    : (overridePath !== ""
    ? "Search result"
    : (dayOffset === 0
      ? "Today"
      : Qt.formatDate(selectedDate, "ddd d MMM") + " (" + (dayOffset > 0 ? "+" : "") + dayOffset + "d)"))

  readonly property string statusNote: {
    if (scanning && comics.length === 0) return "Scanning archive…"
    if (scanFailed) return "No comics found in " + comicsDirSetting
    if (comics.length === 0) return "Loading…"
    return stripDateLabel
  }

  function showToday() {
    root.overridePath = ""
    root.dayOffset = 0
    root.cancelSearch()
  }

  // --------------------------------------------------------------- search
  //
  // Revealed by `/` or the magnify button. While it is open the key catcher
  // is blocked so plain letters land in the field instead of firing the
  // r/t/h/j/k/l shortcuts; the field itself handles Esc/↑/↓/Enter.
  property bool searchOpen: false
  property string searchQuery: ""
  property var searchResults: []
  property int searchMatchCount: 0
  property int searchIndex: -1
  readonly property int searchLimit: 8

  // The highlighted row, shown in the strip area while browsing. Purely
  // derived: closing the search (Esc, the button, reopening the panel) drops
  // it and the strip falls back to the override or the day's pick with no
  // bookkeeping. Enter/click is what makes a pick stick, via overridePath.
  readonly property string previewPath: searchOpen
    && searchIndex >= 0 && searchIndex < searchResults.length
    ? searchResults[searchIndex]
    : ""

  // Focus moves by hand in both directions: the field has to steal it from
  // the panel's focusTarget, and giving it back is what makes the second Esc
  // close the panel the way it always did.
  function openSearch() {
    root.searchOpen = true
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function closeSearch() {
    if (!root.searchOpen) return
    root.searchOpen = false
    keyCatcher.forceActiveFocus()
  }

  // Dismissing (Esc, the button again, reopening the panel) also drops the
  // query; only picking a result keeps it, so `/` reopens where you left off.
  function cancelSearch() {
    searchField.text = ""
    root.closeSearch()
  }

  // AND semantics over whitespace-split tokens. 12k substring probes per
  // token is cheap enough that the 120 ms debounce is about typing comfort,
  // not CPU. Every match is counted but only `searchLimit` rows are built,
  // because reassigning the Repeater model recreates every delegate.
  function runSearch() {
    var q = String(root.searchQuery).trim().toLowerCase()
    if (q === "") {
      root.searchResults = []
      root.searchMatchCount = 0
      root.searchIndex = -1
      return
    }
    var tokens = q.split(/\s+/)
    var out = []
    var count = 0
    for (var i = 0; i < root.haystacks.length; i++) {
      var hay = root.haystacks[i]
      var ok = true
      for (var j = 0; j < tokens.length; j++) {
        if (hay.indexOf(tokens[j]) < 0) { ok = false; break }
      }
      if (!ok) continue
      count++
      if (out.length < root.searchLimit) out.push(root.comics[i])
    }
    root.searchMatchCount = count
    root.searchResults = out
    root.searchIndex = out.length > 0 ? 0 : -1
  }

  function moveSearchIndex(delta) {
    if (root.searchResults.length === 0) return
    var n = root.searchResults.length
    root.searchIndex = ((root.searchIndex + delta) % n + n) % n
  }

  function acceptSearch() {
    if (root.searchResults.length === 0) return
    var idx = root.searchIndex >= 0 ? root.searchIndex : 0
    root.selectResult(root.searchResults[idx])
  }

  // The query text survives on purpose, so `/` reopens where you left off.
  function selectResult(path) {
    root.overridePath = path
    root.closeSearch()
  }

  Timer {
    id: searchDebounce
    interval: 120
    repeat: false
    onTriggered: root.runSearch()
  }

  onSearchQueryChanged: searchDebounce.restart()

  // ----------------------------------------------------------------- copy
  //
  // The strip path goes in as an argv positional ("$1"), never interpolated:
  // archive filenames are full of spaces and the odd apostrophe. magick's
  // "[0]" takes the first frame, and PNG is what other apps actually accept
  // off the clipboard — the raw GIF is the fallback when magick isn't there.
  readonly property string copyScript:
    "set -o pipefail\n" +
    "if magick \"$1[0]\" png:- | wl-copy -t image/png; then exit 0; fi\n" +
    "wl-copy -t \"$(file --mime-type -b \"$1\")\" < \"$1\"\n"

  property string copyStatus: ""
  readonly property bool canCopy: root.comicPath !== "" && !copier.running

  function copyStrip() {
    if (!root.canCopy) return
    copier.command = ["bash", "-c", root.copyScript, "_", root.comicsRoot + "/" + root.comicPath]
    copier.running = true
  }

  Process {
    id: copier
    property string errorText: ""

    onExited: function(exitCode, exitStatus) {
      root.copyStatus = exitCode === 0 ? "Copied" : "Copy failed"
      if (exitCode !== 0) console.log("daily-dilbert copy failed:", exitCode, copier.errorText)
      copyStatusTimer.restart()
    }

    stderr: StdioCollector {
      onStreamFinished: copier.errorText = String(text || "").trim()
    }
  }

  Timer {
    id: copyStatusTimer
    interval: 1500
    repeat: false
    onTriggered: root.copyStatus = ""
  }

  // ---------------------------------------------------------------- scan
  //
  // find is invoked directly (argv, no shell) so the archive path and the
  // parenthesised -iname alternation need no quoting. -printf %P yields
  // paths relative to the archive root, keeping the sorted list identical
  // across machines that store the archive in different places.
  Process {
    id: lister
    command: [
      "find", "-H", root.comicsRoot, "-type", "f",
      "(", "-iname", "*.gif", "-o", "-iname", "*.png",
           "-o", "-iname", "*.jpg", "-o", "-iname", "*.jpeg",
           "-o", "-iname", "*.webp", ")",
      "-printf", "%P\n"
    ]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.applyListing(text)
        root.scanning = false
      }
    }
    stderr: StdioCollector {
      onStreamFinished: {
        if (String(text || "").trim() !== "") console.log("daily-dilbert find:", text)
      }
    }
  }

  Component.onCompleted: refresh()

  // Settings are injected after load; if they point somewhere else, rescan.
  onComicsRootChanged: refresh()

  // Roll the strip over at midnight even if the panel stays open.
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.syncToday()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  // ---------------------------------------------------------------- view
  readonly property int comicWidth: Style.space(700)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.comicWidth)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field owns input every key belongs to it, including
      // the letters this catcher would otherwise claim as shortcuts.
      blocked: root.searchOpen

      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.showToday()
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.overridePath = ""
          root.dayOffset += dx
        }
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "t" || t === "T") root.showToday()
        else if (t === "c" || t === "C") root.copyStrip()
        else if (t === "/") root.openSearch()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Daily Dilbert"
          meta: root.statusNote
          detail: root.selectionLabel
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              text: "󰊪"  // nf-md-glasses
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        // ---- Revealable search. Invisible children take no space in a
        // Column, so the panel's contentHeight (bound to column.implicitHeight)
        // collapses back on its own when the section hides.
        Column {
          id: searchSection
          width: parent.width
          visible: root.searchOpen
          spacing: Style.space(6)

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "Search keywords or date…"
            foreground: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY

            onTextChanged: root.searchQuery = text

            // Return is handled here rather than through TextField's
            // `accepted` signal: QQC2 leaves the key unaccepted so dialogs can
            // see it, and by the time the selection has closed the search the
            // catcher is unblocked again — the same press would reach it as
            // "activate" and immediately reset the pick back to today.
            Keys.onReturnPressed: function(event) { root.acceptSearch(); event.accepted = true }
            Keys.onEnterPressed: function(event) { root.acceptSearch(); event.accepted = true }
            Keys.onEscapePressed: function(event) { root.cancelSearch(); event.accepted = true }
            Keys.onUpPressed: root.moveSearchIndex(-1)
            Keys.onDownPressed: root.moveSearchIndex(1)
            // Swallow Tab: the panel's Tab means "switch bar panel", and
            // letting focus walk out of the field while the catcher is
            // blocked would strand the keyboard with nothing listening.
            Keys.onTabPressed: function(event) { event.accepted = true }
            Keys.onBacktabPressed: function(event) { event.accepted = true }
          }

          Text {
            width: parent.width
            visible: root.searchQuery.trim() !== ""
            text: root.searchMatchCount === 0
              ? "No matches"
              : (root.searchMatchCount > root.searchLimit
                ? root.searchMatchCount + " matches · showing first " + root.searchLimit
                : root.searchMatchCount + (root.searchMatchCount === 1 ? " match" : " matches"))
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.searchResults

            CursorSurface {
              id: resultRow
              width: searchSection.width
              height: Style.space(24)
              foreground: root.foreground
              accent: Color.accent
              hasCursor: index === root.searchIndex

              Text {
                id: resultDate
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                text: root.dateLabelOf(modelData)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // Fill-remaining, never a fixed width: fittedContentWidth can
              // clamp the panel narrower than the requested comic width.
              Text {
                anchors.left: resultDate.right
                anchors.leftMargin: Style.spacing.md
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: root.keywordsOf(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onContainsMouseChanged: if (containsMouse) root.searchIndex = index
                onClicked: root.selectResult(modelData)
              }
            }
          }
        }

        // ---- The strip. White matte behind the image: the scans have white
        // backgrounds, so on dark themes a bare image floats as a harsh
        // rectangle anyway — owning the matte with padding looks deliberate.
        Rectangle {
          id: comicFrame
          width: parent.width

          // Arrowing through search results swaps the source on every press.
          // Qt drops the old pixmap the moment an asynchronous load starts, so
          // without this the frame would blank and snap to the 220px fallback
          // on every keystroke. While a swap is in flight we keep the previous
          // frame painted (stripBack) and hold the last ready height.
          readonly property bool hasFrame: strip.status === Image.Ready
            || (strip.status === Image.Loading && strip.lastPaintedHeight > 0)

          height: comicFrame.hasFrame
            ? (strip.status === Image.Ready ? strip.paintedHeight : strip.lastPaintedHeight) + Style.space(24)
            : Style.space(220)
          radius: Style.cornerRadius
          color: "#ffffff"
          border.width: 1
          border.color: Style.normalBorderFor(root.foreground, Color.accent)

          // Back buffer: it trails one strip behind, because its source only
          // advances when the front image reports Ready. That makes it the
          // last painted frame, which is exactly what should stay on screen
          // while the front image loads the next one (cache hit, so it is
          // already decoded — no crossfade, nothing to pay for).
          Image {
            id: stripBack
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: strip.width
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            source: strip.lastReadyUrl
            visible: strip.status === Image.Loading && stripBack.status === Image.Ready
          }

          Image {
            id: strip
            property string lastReadyUrl: ""
            property real lastPaintedHeight: 0

            // Remembered on the way past Ready: paintedHeight settles after
            // the status change, so watch both.
            function noteReady() {
              if (strip.status !== Image.Ready) return
              if (strip.paintedHeight > 0) strip.lastPaintedHeight = strip.paintedHeight
              strip.lastReadyUrl = String(strip.source)
            }

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(24)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            source: root.comicUrl
            visible: status === Image.Ready
            onStatusChanged: strip.noteReady()
            onPaintedHeightChanged: strip.noteReady()
          }

          // Only when there really is nothing to show: a failed load, an empty
          // archive, or before the first strip has ever painted.
          Text {
            anchors.centerIn: parent
            visible: !comicFrame.hasFrame
            text: strip.status === Image.Error ? "Could not load strip" :
                  (root.scanFailed ? "Archive not found" : "Loading…")
            color: "#666666"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            onClicked: function(mouse) {
              // Middle-click rescans without disturbing a search pick.
              if (mouse.button === Qt.MiddleButton) root.refresh()
              else root.showToday()
            }
          }
        }

        // ---- Keyword caption, when the filename carries one.
        Text {
          width: parent.width
          visible: root.keywordsLabel !== ""
          text: root.keywordsLabel
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        // ---- Footer: archive size left, hint + actions right. The count is
        // anchored against the action row rather than given a width, so a
        // panel clamped narrow by fittedContentWidth elides the caption
        // instead of pushing the buttons off the edge.
        Item {
          width: parent.width
          implicitHeight: Math.max(countLabel.implicitHeight, actions.implicitHeight)

          Text {
            id: countLabel
            anchors.left: parent.left
            anchors.right: actions.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: root.comics.length > 0 ? root.comics.length + " strips · Dilbert by Scott Adams" : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Row {
            id: actions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.sm

            Text {
              id: hint
              anchors.verticalCenter: parent.verticalCenter
              text: root.copyStatus !== ""
                ? root.copyStatus
                : (root.overridePath !== "" || root.dayOffset !== 0
                  ? "←/→ step · T today · C copy"
                  : "←/→ days · / search · C copy")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰍉"  // nf-md-magnify
              tooltipText: "Search the archive"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.searchOpen ? root.cancelSearch() : root.openSearch()
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.copyStatus === "Copied" ? "󰄬" : "󰆏"  // nf-md-check / content_copy
              tooltipText: "Copy strip to clipboard"
              foreground: root.foreground
              fontFamily: root.fontFamily
              // hasFrame, not Image.Ready: a source swap mid-browse shouldn't
              // blink the button out for the length of a load.
              enabled: root.canCopy && comicFrame.hasFrame
              onClicked: root.copyStrip()
            }
          }
        }
      }
    }
  }
}
