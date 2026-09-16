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
    root.dayOffset = 0
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.syncToday()
    root.dayOffset = 0
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
    root.scanFailed = files.length === 0
    root.comics = files
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

  readonly property string comicPath: comics.length > 0 ? comics[pickIndex(selectedStamp, comics.length)] : ""

  readonly property string comicUrl: {
    if (comicPath === "") return ""
    var segments = (comicsRoot + "/" + comicPath).split("/")
    for (var i = 0; i < segments.length; i++) segments[i] = encodeURIComponent(segments[i])
    return "file://" + segments.join("/")
  }

  // Filenames are "<yyyy-mm-dd>_<keyword>_<keyword>….gif"; the date is the
  // strip's original run date, the keywords make a serviceable caption.
  readonly property string comicBasename: {
    var idx = comicPath.lastIndexOf("/")
    return idx >= 0 ? comicPath.substring(idx + 1) : comicPath
  }

  readonly property string stripDateLabel: {
    var m = comicBasename.match(/^(\d{4})-(\d{2})-(\d{2})/)
    if (!m) return ""
    var d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
    return Qt.formatDate(d, "dddd, d MMMM yyyy")
  }

  readonly property string keywordsLabel: {
    var stem = comicBasename.replace(/\.[A-Za-z0-9]+$/, "")
    var m = stem.match(/^\d{4}-\d{2}-\d{2}[_ ]?(.*)$/)
    if (!m || m[1] === "") return ""
    return m[1].split("_").filter(function(k) { return k.trim() !== "" }).join(" · ")
  }

  readonly property string selectionLabel: dayOffset === 0
    ? "Today"
    : Qt.formatDate(selectedDate, "ddd d MMM") + " (" + (dayOffset > 0 ? "+" : "") + dayOffset + "d)"

  readonly property string statusNote: {
    if (scanning && comics.length === 0) return "Scanning archive…"
    if (scanFailed) return "No comics found in " + comicsDirSetting
    if (comics.length === 0) return "Loading…"
    return stripDateLabel
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
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.dayOffset = 0
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.dayOffset += dx
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "t" || t === "T") root.dayOffset = 0
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

        // ---- The strip. White matte behind the image: the scans have white
        // backgrounds, so on dark themes a bare image floats as a harsh
        // rectangle anyway — owning the matte with padding looks deliberate.
        Rectangle {
          id: comicFrame
          width: parent.width
          height: strip.status === Image.Ready
            ? strip.paintedHeight + Style.space(24)
            : Style.space(220)
          radius: Style.cornerRadius
          color: "#ffffff"
          border.width: 1
          border.color: Style.normalBorderFor(root.foreground, Color.accent)

          Image {
            id: strip
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(24)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: true
            source: root.comicUrl
            visible: status === Image.Ready
          }

          Text {
            anchors.centerIn: parent
            visible: strip.status !== Image.Ready
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
              if (mouse.button === Qt.MiddleButton) root.refresh()
              else root.dayOffset = 0
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

        // ---- Footer: archive size left, interaction hint right.
        Item {
          width: parent.width
          implicitHeight: Math.max(countLabel.implicitHeight, hint.implicitHeight)

          Text {
            id: countLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.comics.length > 0 ? root.comics.length + " strips · Dilbert by Scott Adams" : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: hint
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.dayOffset === 0 ? "←/→ other days · R rescan" : "←/→ step · T today"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
