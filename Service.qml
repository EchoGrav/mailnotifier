import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omafmail/config.json"
  readonly property string stateDir: home + "/.local/state/omafmail"
  readonly property string statePath: stateDir + "/state.json"
  readonly property string watcherScriptPath: manifest && manifest.__sourceDir
    ? manifest.__sourceDir + "/scripts/idle_watcher.py"
    : ""

  property var config: null
  property string configError: ""
  property bool configReady: false
  property bool stateReady: false
  property bool hasPersistedBaseline: false
  property var knownIds: ({})

  property var messages: []
  property int unreadCount: 0
  property string connectionState: "disconnected" // disconnected | connecting | idle | error
  property var lastError: null
  property int consecutiveFailures: 0
  property bool manualReconnectRequested: false

  readonly property bool checking: connectionState === "connecting"

  function maybeStart() {
    if (!root.configReady || !root.stateReady) return
    if (!root.config || root.watcherScriptPath === "") return
    if (watcherProcess.running) return
    root.startWatcher()
  }

  function startWatcher() {
    root.connectionState = "connecting"
    root.manualReconnectRequested = false
    watcherProcess.command = ["python3", root.watcherScriptPath, root.configPath]
    watcherProcess.running = true
  }

  function forceReconnect() {
    root.manualReconnectRequested = true
    root.consecutiveFailures = 0
    restartTimer.stop()
    configFile.reload() // also recovers from a config file that didn't exist yet
  }

  function scheduleRestart() {
    var delaySeconds
    if (root.manualReconnectRequested) {
      delaySeconds = 0.2
      root.manualReconnectRequested = false
    } else {
      var kind = root.lastError ? root.lastError.kind : ""
      if (kind === "auth" || kind === "config") {
        delaySeconds = 300 // retrying immediately won't fix a bad password or mailbox name
      } else {
        root.consecutiveFailures++
        var tiers = [2, 5, 15, 30, 60]
        delaySeconds = tiers[Math.min(root.consecutiveFailures - 1, tiers.length - 1)]
      }
    }
    restartTimer.interval = Math.round(delaySeconds * 1000)
    restartTimer.restart()
  }

  function loadConfig(raw) {
    try {
      root.config = Model.normalizeConfig(JSON.parse(String(raw || "")))
      root.configError = ""
    } catch (error) {
      root.config = null
      root.configError = String(error)
      console.warn("omafmail: config error:", root.configError)
    }
    root.configReady = true
    root.consecutiveFailures = 0
    if (watcherProcess.running) {
      root.manualReconnectRequested = true
      watcherProcess.running = false
    } else {
      root.maybeStart()
    }
  }

  function loadState(raw) {
    var stored = {}
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      if (parsed && parsed.knownIds && typeof parsed.knownIds === "object") stored = parsed.knownIds
    } catch (error) {
      console.warn("omafmail: state error:", String(error))
    }
    root.knownIds = stored
    root.hasPersistedBaseline = true
    root.stateReady = true
    root.maybeStart()
  }

  function statePayload() {
    return { version: 1, knownIds: root.knownIds }
  }

  function persistState() {
    if (!root.stateReady) return
    stateFile.setText(JSON.stringify(root.statePayload(), null, 2) + "\n")
  }

  readonly property string openMailClientScriptPath: manifest && manifest.__sourceDir
    ? manifest.__sourceDir + "/scripts/open_mail_client.sh"
    : ""

  function openMailClient() {
    if (root.openMailClientScriptPath === "") return
    Quickshell.execDetached(["sh", root.openMailClientScriptPath])
  }

  function sendNotification(title, body, urgency, glyph) {
    if (notifyProcess.running) {
      // A previous notification's click-listener is still waiting for
      // input; don't stomp on it, just send this one without a click
      // action rather than losing the earlier one's action handling.
      Quickshell.execDetached([
        "omarchy-notification-send",
        "--app-name", "omafmail",
        "--urgency", urgency,
        "--glyph", glyph,
        title,
        body
      ])
      return
    }
    notifyProcess.command = [
      "omarchy-notification-send",
      "--app-name", "omafmail",
      "--urgency", urgency,
      "--glyph", glyph,
      "--action", "default=Open",
      title,
      body
    ]
    notifyProcess.running = true
  }

  function notifyNew(newMessages) {
    if (newMessages.length === 1) {
      var m = newMessages[0]
      var body = m.snippet ? (m.subject + " — " + m.snippet) : m.subject
      root.sendNotification(m.fromName, body, "normal", "󰇮")
    } else {
      var lines = []
      var shown = Math.min(newMessages.length, 5)
      for (var i = 0; i < shown; i++) lines.push(newMessages[i].fromName + ": " + newMessages[i].subject)
      if (newMessages.length > shown) lines.push("+" + (newMessages.length - shown) + " more")
      root.sendNotification(newMessages.length + " new messages", lines.join("\n"), "normal", "󰇮")
    }
  }

  function applySnapshot(messages) {
    var idSet = {}
    var newMessages = []
    for (var i = 0; i < messages.length; i++) {
      var id = messages[i].id
      idSet[id] = true
      if (root.hasPersistedBaseline && !root.knownIds[id]) newMessages.push(messages[i])
    }
    root.messages = messages
    root.unreadCount = messages.length
    if (newMessages.length > 0) root.notifyNew(newMessages)
    root.knownIds = idSet
    root.hasPersistedBaseline = true
    stateWriteTimer.restart()
  }

  function handleLine(line) {
    var event
    try {
      event = JSON.parse(line)
    } catch (error) {
      console.warn("omafmail: unreadable watcher output:", line)
      return
    }
    if (event.type === "status" && event.state === "connected") {
      root.connectionState = "idle"
      root.lastError = null
      root.consecutiveFailures = 0
    } else if (event.type === "snapshot") {
      root.connectionState = "idle"
      root.lastError = null
      root.consecutiveFailures = 0
      root.applySnapshot(Array.isArray(event.messages) ? event.messages : [])
    } else if (event.type === "error") {
      root.lastError = { kind: String(event.kind || "network"), message: String(event.message || "") }
      root.connectionState = "error"
      console.warn("omafmail:", root.lastError.kind, root.lastError.message)
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfig(text())
    onLoadFailed: function(error) {
      root.config = null
      root.configError = "Create " + root.configPath + " from config.example.json"
      root.configReady = true
    }
    onFileChanged: reload()
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    onLoadFailed: {
      root.knownIds = ({})
      root.hasPersistedBaseline = false
      root.stateReady = true
      root.maybeStart()
    }
  }

  Process {
    command: ["mkdir", "-p", root.stateDir]
    running: true
    onExited: stateFile.reload()
  }

  Timer {
    id: stateWriteTimer
    interval: 250
    repeat: false
    onTriggered: root.persistState()
  }

  Timer {
    id: restartTimer
    repeat: false
    onTriggered: {
      if (!watcherProcess.running) {
        root.connectionState = "connecting"
        watcherProcess.running = true
      }
    }
  }

  // --action implies --wait, so this process stays alive until the
  // notification is clicked or dismissed, printing the chosen action
  // name ("default" for a plain click) to stdout.
  Process {
    id: notifyProcess
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) {
        if (String(line).trim() === "default") root.openMailClient()
      }
    }
    onExited: {
      notifyProcess.running = false
    }
  }

  Process {
    id: watcherProcess
    running: false
    command: []
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn("omafmail(stderr):", line) }
    }
    onExited: function(exitCode) {
      if (root.manualReconnectRequested) {
        // Deliberate kill-to-restart (config reload or a user-triggered
        // reconnect) — not a real error, so don't flash "connection lost".
        root.connectionState = "connecting"
        root.lastError = null
      } else {
        root.connectionState = "error"
        if (!root.lastError) root.lastError = { kind: "network", message: "watcher exited (code " + exitCode + ")" }
      }
      root.scheduleRestart()
    }
  }
}
