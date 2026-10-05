import QtQuick
import QtQuick.Controls
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar search over an Obsidian vault.
//
// The bar entry is a text label. Left click opens a panel with a search
// field and a ranked note list. Enter opens the note in Obsidian. New notes
// are written under <vault>/Notes. Existing notes can be edited here or
// moved into <vault>/.trash after a second confirmation.
Panel {
  id: root

  moduleName: "design-nexus.obsidian-notes"
  ipcTarget: "design-nexus.obsidian-notes"

  // Popup content must stay readable when the bar is double-clicked to
  // transparent. bar.barForeground is intentionally animated to contrast the
  // wallpaper behind a transparent bar (via omarchy-bar-text-color), so it
  // can become near-black on light wallpapers while the popup card stays
  // Color.popups.background (dark). Using barForeground inside the popup
  // therefore makes dark-on-dark unreadable. Use the popup surface palette.
  readonly property color foreground: Color.popups.text
  readonly property color dim: Util.alpha(Color.popups.text, 0.62)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string configuredVaultPath: String(root.setting("vaultPath", "")).trim()
  readonly property string vaultPath: configuredVaultPath.indexOf("~/") === 0
    ? (Quickshell.env("HOME") || "") + configuredVaultPath.slice(1)
    : configuredVaultPath
  readonly property string pluginDir: (Quickshell.env("HOME") || "")
    + "/.config/omarchy/plugins/design-nexus.obsidian-notes"
  readonly property string searchCommand: pluginDir + "/search.sh"
  readonly property string createCommand: pluginDir + "/create-note.sh"
  readonly property string readCommand: pluginDir + "/read-note.sh"
  readonly property string writeCommand: pluginDir + "/write-note.sh"
  readonly property string deleteCommand: pluginDir + "/delete-note.sh"

  property var results: []
  property int selectedIndex: -1
  property bool searching: false
  property bool choosingVault: false
  property bool composing: false
  property bool saving: false
  property bool deleting: false
  property bool loadingNote: false
  property string editingPath: ""
  property string loadedTitle: ""
  property string loadedBody: ""
  property bool discardArmed: false
  property string deleteArmedPath: ""
  property string pendingBody: ""
  property string saveOutput: ""
  property string saveError: ""
  property string lastError: ""
  property string notice: ""

  readonly property int maxRows: 8
  readonly property real rowHeight: Style.space(56)
  readonly property string query: filterField.text.trim()
  readonly property bool empty: !searching && results.length === 0 && lastError === ""
  readonly property bool editorDirty: titleField.text !== loadedTitle || noteEditor.text !== loadedBody

  readonly property string footerText: {
    if (deleteArmedPath !== "") return "Delete this note? Press Delete again   ·   Esc cancel"
    if (searching) return "Searching…"
    if (lastError) return lastError
    if (notice) return notice
    return "↑↓  Enter open  ^N new  ^E edit  ^L link  Del delete"
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function vaultName() {
    var parts = String(root.vaultPath).split("/").filter(function(p) { return p !== "" })
    return parts.length > 0 ? parts[parts.length - 1] : root.vaultPath
  }

  function encode(s) {
    return String(s)
      .replace(/%/g, "%25").replace(/ /g, "%20").replace(/#/g, "%23")
      .replace(/\?/g, "%3F").replace(/&/g, "%26")
      .replace(/'/g, "%27").replace(/"/g, "%22")
  }

  function obsidianUri(relPath) {
    var file = String(relPath || "").replace(/\.md$/, "")
    return "obsidian://open?vault=" + root.encode(root.vaultName()) + "&file=" + root.encode(file)
  }

  function wikiLink(relPath) {
    return "[[" + String(relPath || "").replace(/\.md$/, "") + "]]"
  }

  // Vault content is untrusted input. QML Text defaults to AutoText, which
  // would let the shared shell process fetch remote resources. Note strings
  // are plain text, and Button labels are entity-escaped.
  function escapeHtml(s) {
    return String(s === null || s === undefined ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }

  function whenText(epoch) {
    if (epoch === null || epoch === undefined || isNaN(Number(epoch))) return ""
    var d = new Date(Number(epoch) * 1000)
    var now = new Date()
    var pad = function(n) { return n < 10 ? "0" + n : String(n) }
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()) {
      return "today " + pad(d.getHours()) + ":" + pad(d.getMinutes())
    }
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return pad(d.getDate()) + " " + months[d.getMonth()]
  }

  function selectedPath() {
    if (root.selectedIndex < 0 || root.selectedIndex >= root.results.length) return ""
    var note = root.results[root.selectedIndex]
    return note && note.path ? String(note.path) : ""
  }

  function runSearch() {
    if (searchProcess.running) return
    if (root.vaultPath === "") {
      root.searching = false
      root.results = []
      root.selectedIndex = -1
      root.lastError = "Select your vault folder to get started"
      return
    }
    root.searching = true
    root.lastError = ""
    searchProcess.command = [root.searchCommand, root.vaultPath, filterField.text]
    searchProcess.running = true
    searchDeadline.restart()
  }

  function persistVaultPath(path) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.vaultPath = String(path || "")

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)

    filterField.text = ""
    root.lastError = ""
    Qt.callLater(root.runSearch)
  }

  function localPath(fileUrl) {
    var value = String(fileUrl || "")
    if (value.indexOf("file://") === 0) value = value.slice(7)
    try { return decodeURIComponent(value) }
    catch (e) { return value }
  }

  function parseResults(raw) {
    searchDeadline.stop()
    var text = String(raw || "").trim()
    root.searching = false
    if (text === "") {
      root.results = []
      root.selectedIndex = -1
      return
    }
    try {
      var parsed = JSON.parse(text)
      root.results = (parsed && Array.isArray(parsed)) ? parsed : []
    } catch (e) {
      console.warn(root.moduleName + ": invalid search output", e)
      root.lastError = "Invalid search response"
      root.results = []
    }
    root.selectedIndex = root.results.length > 0 ? 0 : -1
    if (root.selectedIndex >= 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function move(delta) {
    var n = root.results.length
    root.deleteArmedPath = ""
    if (n <= 0) return
    root.selectedIndex = Math.max(0, Math.min(n - 1, root.selectedIndex + delta))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function openPath(relPath) {
    if (!relPath) return
    root.close()
    var uri = root.obsidianUri(relPath)
    Qt.callLater(function() {
      Quickshell.execDetached(["xdg-open", uri])
    })
  }

  function openNote() {
    root.openPath(root.selectedPath())
  }

  function copyLink() {
    var path = root.composing ? root.editingPath : root.selectedPath()
    if (path === "") return
    var link = root.wikiLink(path)
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(link) + " | wl-copy"])
    root.notice = "Link copied"
    noticeTimer.restart()
  }

  function handleListShortcut(event) {
    if (!(event.modifiers & Qt.ControlModifier)) return false
    if (event.key === Qt.Key_N) {
      root.startComposing()
      event.accepted = true
      return true
    }
    if (event.key === Qt.Key_E) {
      root.startEditing()
      event.accepted = true
      return true
    }
    if (event.key === Qt.Key_L) {
      root.copyLink()
      event.accepted = true
      return true
    }
    return false
  }

  function startComposing() {
    if (root.vaultPath === "") return
    root.choosingVault = false
    root.composing = true
    root.editingPath = ""
    root.loadingNote = false
    root.saveError = ""
    root.discardArmed = false
    root.deleteArmedPath = ""
    root.loadedTitle = ""
    root.loadedBody = ""
    titleField.text = ""
    noteEditor.text = ""
    Qt.callLater(function() { titleField.forceActiveFocus() })
  }

  function startEditing() {
    var path = root.selectedPath()
    if (path === "" || root.vaultPath === "") return
    root.choosingVault = false
    root.composing = true
    root.editingPath = path
    root.loadingNote = true
    root.saving = false
    root.saveError = ""
    root.discardArmed = false
    root.deleteArmedPath = ""
    root.loadedTitle = ""
    root.loadedBody = ""
    titleField.text = ""
    noteEditor.text = ""
    readProcess.command = [root.readCommand, root.vaultPath, path]
    readProcess.running = true
  }

  function applyLoadedNote(raw) {
    root.loadingNote = false
    var text = String(raw || "").trim()
    if (text.indexOf("ERR\t") === 0) {
      root.composing = false
      root.editingPath = ""
      root.lastError = text.slice(4)
      return
    }
    try {
      var parsed = JSON.parse(text)
      titleField.text = String(parsed.title || "")
      noteEditor.text = String(parsed.body || "")
      root.loadedTitle = titleField.text
      root.loadedBody = noteEditor.text
      root.discardArmed = false
      Qt.callLater(function() { titleField.forceActiveFocus() })
    } catch (e) {
      console.warn(root.moduleName + ": invalid note", e)
      root.composing = false
      root.editingPath = ""
      root.lastError = "Could not read the note"
    }
  }

  function cancelComposing() {
    root.composing = false
    root.editingPath = ""
    root.loadingNote = false
    root.saveError = ""
    root.discardArmed = false
    root.deleteArmedPath = ""
    titleField.text = ""
    noteEditor.text = ""
    Qt.callLater(function() { filterField.forceActiveFocus() })
  }

  function requestCancel() {
    if (root.deleteArmedPath !== "") {
      root.deleteArmedPath = ""
      return
    }
    if (root.editorDirty && !root.discardArmed) {
      root.discardArmed = true
      root.saveError = "Unsaved changes. Press Escape again to discard"
      return
    }
    root.cancelComposing()
  }

  function saveNote() {
    if (root.saving || root.loadingNote) return
    var title = titleField.text.trim()
    var body = noteEditor.text
    if (root.editingPath === "" && title === "" && body.trim() === "") {
      root.saveError = "Add a title or write something before saving"
      return
    }
    if (root.editingPath !== "" && title === "") {
      root.saveError = "Add a title before saving"
      return
    }
    root.saving = true
    root.saveError = ""
    root.discardArmed = false
    root.pendingBody = body
    root.saveOutput = ""
    var proc = root.editingPath === "" ? createProcess : writeProcess
    proc.stdinEnabled = true
    proc.command = root.editingPath === ""
      ? [root.createCommand, root.vaultPath, title]
      : [root.writeCommand, root.vaultPath, root.editingPath, title]
    proc.running = true
  }

  function finishSave(exitCode) {
    root.saving = false
    var text = String(root.saveOutput || "").trim()
    if (exitCode === 0 && text.indexOf("OK\t") === 0) {
      root.composing = false
      root.editingPath = ""
      root.loadedTitle = ""
      root.loadedBody = ""
      titleField.text = ""
      noteEditor.text = ""
      filterField.text = ""
      root.runSearch()
      Qt.callLater(function() { filterField.forceActiveFocus() })
      return
    }
    root.saveError = text.indexOf("ERR\t") === 0
      ? text.slice(4)
      : "Could not save the note (error " + exitCode + ")"
  }

  function requestDelete() {
    if (root.deleting || root.saving) return
    var path = root.composing ? root.editingPath : root.selectedPath()
    if (path === "") return
    if (root.deleteArmedPath !== path) {
      root.deleteArmedPath = path
      root.discardArmed = false
      return
    }
    root.deleting = true
    root.deleteArmedPath = ""
    root.saveError = ""
    deleteProcess.command = [root.deleteCommand, root.vaultPath, path]
    deleteProcess.running = true
  }

  function editorShortcut(event) {
    if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
      root.saveNote()
      event.accepted = true
      return
    }
    if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_L) {
      root.copyLink()
      event.accepted = true
    }
  }

  onOpenedChanged: if (opened) {
    filterField.text = ""
    root.composing = false
    root.editingPath = ""
    root.saveError = ""
    root.notice = ""
    root.deleteArmedPath = ""
    root.discardArmed = false
    root.choosingVault = root.vaultPath === ""
    if (!root.choosingVault) root.runSearch()
    Qt.callLater(function() {
      if (!root.choosingVault) filterField.forceActiveFocus()
    })
  }

  Component.onCompleted: root.runSearch()

  Process {
    id: searchProcess
    command: []
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseResults(text)
    }

    onExited: function(exitCode) {
      searchDeadline.stop()
      root.searching = false
      if (exitCode !== 0 && root.lastError === "") {
        console.warn(root.moduleName + ": search command exited", exitCode)
        root.lastError = (exitCode === 124 || exitCode === 143) ? "Search timed out" : "Search failed (error " + exitCode + ")"
      }
    }
  }

  Timer {
    id: searchDeadline
    interval: 4500
    repeat: false
    onTriggered: {
      if (searchProcess.running) {
        searchProcess.running = false
        root.searching = false
        if (root.lastError === "") root.lastError = "Search timed out"
      }
    }
  }

  Process {
    id: readProcess
    command: []
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (root.loadingNote) root.applyLoadedNote(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.loadingNote) {
        root.loadingNote = false
        root.composing = false
        root.editingPath = ""
        if (root.lastError === "") root.lastError = "Could not read the note (error " + exitCode + ")"
      }
    }
  }

  Process {
    id: createProcess
    command: []
    running: false
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.saveOutput = text
    }
    onStarted: {
      write(root.pendingBody)
      stdinEnabled = false
    }
    onExited: function(exitCode) { root.finishSave(exitCode) }
  }

  Process {
    id: writeProcess
    command: []
    running: false
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.saveOutput = text
    }
    onStarted: {
      write(root.pendingBody)
      stdinEnabled = false
    }
    onExited: function(exitCode) { root.finishSave(exitCode) }
  }

  Process {
    id: deleteProcess
    command: []
    running: false
    stdout: StdioCollector {
      id: deleteOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.deleting = false
      var text = String(deleteOutput.text || "").trim()
      if (exitCode !== 0 || text.indexOf("OK\t") !== 0) {
        root.lastError = text.indexOf("ERR\t") === 0 ? text.slice(4) : "Could not delete the note"
        root.saveError = root.composing ? root.lastError : ""
        return
      }
      if (root.composing) root.cancelComposing()
      root.runSearch()
    }
  }

  Timer {
    id: noticeTimer
    interval: 2000
    repeat: false
    onTriggered: root.notice = ""
  }

  FolderListModel {
    id: folderModel
    folder: "file://" + (root.vaultPath || Quickshell.env("HOME") || "/")
    showDirs: true
    showFiles: false
    showDirsFirst: true
    showDotAndDotDot: false
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "Notes"
    fontSize: Style.font.bodySmall
    horizontalMargin: 6.5
    tooltipText: "Search Obsidian notes"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) {
        if (root.vaultPath !== "")
          Quickshell.execDetached(["xdg-open", "obsidian://open?vault=" + root.encode(root.vaultName())])
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.composing ? titleField : filterField
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: filterField.activeFocus || titleField.activeFocus || noteEditor.activeFocus

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.move(dy) }
      onActivateRequested: root.openNote()
      onReturnRequested: root.openNote()
      onCloseRequested: {
        if (root.composing) root.requestCancel()
        else if (root.deleteArmedPath !== "") root.deleteArmedPath = ""
        else root.close()
      }
      onDeleteRequested: root.requestDelete()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        filterField.insert(filterField.cursorPosition, t)
        filterField.forceActiveFocus()
      }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.spacing.md

        Row {
          visible: !root.choosingVault && !root.composing
          width: parent.width
          spacing: Style.spacing.sm

          TextField {
            id: filterField
            width: parent.width - addButton.width - editButton.width - deleteButton.width - vaultButton.width - parent.spacing * 4
            placeholderText: root.vaultPath === "" ? "Select a vault…" : "Search the vault…"
            foreground: root.foreground
            enabled: root.vaultPath !== ""

            onTextChanged: {
              root.deleteArmedPath = ""
              filterTimer.restart()
            }
            onAccepted: root.openNote()
            Keys.onUpPressed: root.move(-1)
            Keys.onDownPressed: root.move(1)
            Keys.onEscapePressed: {
              if (root.deleteArmedPath !== "") root.deleteArmedPath = ""
              else if (filterField.text !== "") filterField.text = ""
              else root.close()
            }
            Keys.onDeletePressed: function(event) {
              if (filterField.text === "") {
                root.requestDelete()
                event.accepted = true
              }
            }
            Keys.onPressed: function(event) { root.handleListShortcut(event) }
          }

          Button {
            id: addButton
            text: "+"
            tooltipText: "Create a note  Ctrl+N"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.title
            bordered: true
            focusable: true
            onClicked: root.startComposing()
          }

          Button {
            id: editButton
            text: "Edit"
            tooltipText: "Edit the selected note  Ctrl+E"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            focusable: true
            enabled: root.selectedPath() !== ""
            onClicked: root.startEditing()
          }

          Button {
            id: deleteButton
            text: root.deleteArmedPath !== "" && root.deleteArmedPath === root.selectedPath() ? "Confirm" : "Del"
            tooltipText: "Move the selected note to trash"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            focusable: true
            enabled: root.selectedPath() !== "" && !root.deleting
            onClicked: root.requestDelete()
          }

          Button {
            id: vaultButton
            iconText: "󰒓"
            tooltipText: "Change vault"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconSize: Style.font.icon
            horizontalPadding: Style.space(7)
            bordered: true
            focusable: true
            onClicked: {
              folderModel.folder = "file://" + (root.vaultPath || Quickshell.env("HOME") || "/")
              root.choosingVault = true
              root.deleteArmedPath = ""
            }
          }
        }

        Column {
          visible: root.composing && !root.choosingVault
          width: parent.width
          spacing: Style.spacing.sm

          Text {
            width: parent.width
            text: root.editingPath === "" ? "New note · Notes" : root.editingPath
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: titleField
            width: parent.width
            placeholderText: "Title"
            foreground: root.foreground
            enabled: !root.saving && !root.loadingNote
            maximumLength: 200
            onTextChanged: root.discardArmed = false
            Keys.onEscapePressed: root.requestCancel()
            Keys.onPressed: function(event) { root.editorShortcut(event) }
          }

          TextArea {
            id: noteEditor
            width: parent.width
            height: Style.space(220)
            placeholderText: root.loadingNote ? "Loading…" : "Write your note…"
            color: root.foreground
            placeholderTextColor: root.dim
            selectionColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.25)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: TextEdit.Wrap
            readOnly: root.saving || root.loadingNote
            padding: Style.space(10)
            background: Rectangle {
              color: "transparent"
              radius: Style.cornerRadius
              border.color: root.dim
              border.width: 1
            }
            onTextChanged: root.discardArmed = false
            Keys.onEscapePressed: root.requestCancel()
            Keys.onPressed: function(event) { root.editorShortcut(event) }
          }

          Text {
            visible: root.saveError !== ""
            width: parent.width
            text: root.saveError
            textFormat: Text.PlainText
            color: root.bar ? root.bar.urgent : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Row {
            spacing: Style.spacing.sm

            Button {
              text: root.saving ? "Saving…" : "Save"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              focusable: true
              enabled: !root.saving && !root.loadingNote
              onClicked: root.saveNote()
            }

            Button {
              text: "Cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              focusable: true
              enabled: !root.saving
              onClicked: root.cancelComposing()
            }

            Button {
              visible: root.editingPath !== ""
              text: "Open"
              tooltipText: "Open in Obsidian"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              focusable: true
              onClicked: root.openPath(root.editingPath)
            }

            Button {
              visible: root.editingPath !== ""
              text: root.deleteArmedPath === root.editingPath ? "Confirm delete" : "Delete"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              focusable: true
              enabled: !root.deleting && !root.loadingNote
              onClicked: root.requestDelete()
            }
          }
        }

        Column {
          visible: root.choosingVault
          width: parent.width
          spacing: Style.spacing.sm

          Text {
            width: parent.width
            text: root.localPath(folderModel.folder)
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            Button {
              text: "Up"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              enabled: String(folderModel.parentFolder) !== ""
              onClicked: folderModel.folder = folderModel.parentFolder
            }

            Button {
              text: "Use this folder"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: {
                root.persistVaultPath(root.localPath(folderModel.folder))
                root.choosingVault = false
              }
            }

            Button {
              visible: root.vaultPath !== ""
              text: "Cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.choosingVault = false
            }
          }

          ListView {
            id: folderList
            width: parent.width
            height: root.rowHeight * 6
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: folderModel
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: Button {
              required property int index
              required property string fileName
              required property url fileUrl
              width: folderList.width
              text: root.escapeHtml(fileName)
              leftAlign: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: folderModel.folder = fileUrl
            }
          }
        }

        Timer {
          id: filterTimer
          interval: 200
          repeat: false
          onTriggered: root.runSearch()
        }

        ListView {
          id: resultList
          visible: !root.choosingVault && !root.composing
          width: parent.width
          height: Math.min(root.results.length, root.maxRows) * root.rowHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: root.results.length > root.maxRows
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.results
          currentIndex: root.selectedIndex

          delegate: Rectangle {
            id: row
            required property int index
            readonly property var note: root.results[index] || ({})
            width: resultList.width
            height: root.rowHeight
            radius: Style.space(4)
            color: root.selectedIndex === index
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
              : "transparent"

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              onEntered: root.selectedIndex = index
              onPositionChanged: root.selectedIndex = index
              onClicked: {
                root.selectedIndex = index
                root.openNote()
              }
            }

            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: row.note.title || row.note.path || "…"
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                width: parent.width
                text: row.note.path || ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                width: parent.width
                visible: (row.note.snippet || "") !== ""
                text: row.note.snippet || ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.rightMargin: Style.space(10)
              anchors.topMargin: Style.space(8)
              text: root.whenText(row.note.modified)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          id: emptyText
          width: parent.width
          visible: !root.choosingVault && !root.composing && root.empty
          text: root.query === "" ? "The vault is empty or cannot be read" : "No results for “" + root.query + "”"
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
          padding: Style.space(24)
        }

        Text {
          width: parent.width
          visible: !root.choosingVault && !root.composing
          text: root.footerText
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
