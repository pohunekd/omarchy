import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// pohunek in the Omarchy bar, modelled on the pohunek companions
// (https://pohunek.dev/surfaces/android/): every session on every followed
// host, the ones that need you on top, your groups shared through the
// `companion.group` key, filters under your thumb, and a sheet of actions per
// row. Attach opens a real terminal (Ctrl-] detaches, the agent keeps
// running).
Panel {
  id: root
  moduleName: "pohunek.sessions"
  ipcTarget: "pohunek.sessions"
  manageIpc: false

  // ---------------------------------------------------------------- colours
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property color chipFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // State colours from the theme palette (colors.toml), like the companions'
  // amber / green / blue; fall back to the shell roles.
  property var themePalette: ({})
  function themeColor(name, fallback) { return themePalette[name] ? themePalette[name] : fallback }
  function stateColor(state) {
    switch (state) {
    case "needs": return themeColor("orange", themeColor("yellow", root.urgent))
    case "working": return themeColor("green", root.foreground)
    case "idle": return themeColor("blue", root.dim)
    case "problem": return themeColor("red", root.urgent)
    default: return root.dim
    }
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }
  function t(key, fallback) { return strings.t(key, fallback === undefined ? key : fallback) }
  function stateLabel(state) { return t("state." + state) }

  // ------------------------------------------------------------------ state
  property string page: "list"          // list | details | hosts | new
  property string sheet: ""             // "" | actions | view | menu | state | project | host | group | rename | newGroup | confirm
  property var sheetRow: null           // row the sheet acts on
  property string confirmAction: ""     // stop | remove
  property int sheetCursor: 0
  property bool searchOpen: false
  property var filters: ({ query: "", states: [], project: "", host: "" })
  property int cursor: 0
  property bool cursorActive: false
  property var detailRow: null
  property string pickerQuery: ""

  readonly property string view: pohunek.layout.view === "state" ? "state" : "groups"
  readonly property var visibleRows: Model.applyFilters(pohunek.rows, filters)
  readonly property var sectionList: Model.sections(visibleRows, view, pohunek.layout)
  readonly property var items: Model.flatten(sectionList)
  readonly property var projectChoices: Model.projects(pohunek.rows, pohunek.layout.recentProjects)
  readonly property var groupChoices: Model.groupNames(pohunek.rows, pohunek.layout)
  readonly property bool multiHost: pohunek.hosts.length >= 2
  readonly property var unreachableHosts: pohunek.hosts.filter(function(h) { return !h.reachable })

  function current() { return items.length > 0 ? items[Math.max(0, Math.min(cursor, items.length - 1))] : null }
  function currentRow() { var c = current(); return c && c.type === "row" ? c.row : null }

  onItemsChanged: if (cursor >= items.length) cursor = Math.max(0, items.length - 1)

  function moveCursor(dy) {
    if (items.length === 0) return
    cursorActive = true
    cursor = Math.max(0, Math.min(items.length - 1, cursor + dy))
    scrollToCursor()
  }

  function scrollToCursor() {
    var flick = listFlick()
    if (!flick) return
    Qt.callLater(function() {
      var column = flick.contentItem.children[0]
      if (!column) return
      for (var i = 0; i < column.children.length; i++) {
        var child = column.children[i]
        if (child.itemIndex !== root.cursor) continue
        var top = child.y, bottom = top + child.height, margin = Style.space(8)
        if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
        else if (bottom > flick.contentY + flick.height - margin)
          flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), bottom + margin - flick.height)
        return
      }
    })
  }

  function listFlick() { return panel.loadedContent ? panel.loadedContent.listFlick : null }

  function activate() {
    var c = current()
    if (!c) return
    if (c.type === "header") { if (c.section.kind !== "needs") pohunek.toggleCollapsed(c.section.id) }
    else attachRow(c.row)
  }

  function attachRow(row) {
    if (!row) return
    if (row.ownerState === "ended") { openSheet("actions", row); return }
    pohunek.attach(row)
    root.close()
  }

  function openSheet(name, row) {
    sheet = name
    sheetRow = row || null
    sheetCursor = 0
    pickerQuery = ""
  }
  function closeSheet() { sheet = ""; sheetRow = null; confirmAction = ""; refocus() }
  function refocus() { Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() }) }

  function showDetails(row) { detailRow = row; page = "details"; closeSheet() }
  function back() {
    if (sheet !== "") { closeSheet(); return }
    if (searchOpen) { searchOpen = false; refocus(); return }
    if (page !== "list") { page = "list"; refocus(); return }
    root.close()
  }

  function setFilter(key, value) {
    var next = Object.assign({}, filters)
    next[key] = value
    filters = next
    cursor = 0
  }
  function toggleState(state) {
    var list = (filters.states || []).slice()
    var i = list.indexOf(state)
    if (i >= 0) list.splice(i, 1); else list.push(state)
    setFilter("states", list)
  }
  function clearFilters() { filters = { query: "", states: [], project: "", host: "" }; searchOpen = false; cursor = 0 }

  function newSessionFrom(row) {
    var host = row ? row.host : (filters.host || "local")
    if (!panel.loadedContent) return
    panel.loadedContent.newForm.reset(host, row ? row.project : (filters.project || ""), row ? row.group : "")
    page = "new"
    closeSheet()
  }

  function ageText(ms) {
    var parts = Model.ageParts(pohunek.now, ms)
    if (parts.key === "") return ""
    if (parts.key === "age.now") return t("age.now")
    return strings.tn(parts.key, parts.count).arg(Commons.I18n.formatNumber(parts.count))
  }

  function sectionTitle(sec) {
    if (sec.kind === "needs") return t("section.needsYou")
    if (sec.kind === "state") return stateLabel(sec.state)
    return sec.inbox ? t("group.inbox") : sec.name
  }

  readonly property string tooltip: {
    var c = pohunek.counts
    if (c.state === "missing") return t("tooltip.notInstalled")
    if (c.state === "offline") return t("tooltip.offline")
    return t("tooltip.summary").arg(Commons.I18n.formatNumber(c.needs)).arg(Commons.I18n.formatNumber(c.working))
      .arg(Commons.I18n.formatNumber(c.idle))
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    page = "list"; sheet = ""; searchOpen = false; cursorActive = false; cursor = 0
    if (listFlick()) listFlick().contentY = 0
    refocus()
  }

  property alias service: pohunek
  readonly property Item panelContent: panel.loadedContent

  Service {
    id: pohunek
    settings: root.settings
    panelOpen: root.opened
    strings: strings
  }

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var out = {}
      var lines = String(text() || "").split("\n")
      for (var i = 0; i < lines.length; i++) {
        var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/)
        if (m) out[m[1]] = m[2]
      }
      root.themePalette = out
    }
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { pohunek.refresh(true); return "ok" }
    function status(): string { return pohunek.counts.state }
    function needs(): string { return String(pohunek.counts.needs) }
    function newSession(): void { root.open(); Qt.callLater(function() { root.newSessionFrom(null) }) }
    // Opens the panel on one page: list | state | help | hosts | new | actions
    // (actions: the sheet of the first session that needs you, else the first row).
    function page(name: string): string {
      root.open()
      Qt.callLater(function() {
        root.sheet = ""; root.page = "list"
        if (name === "state" || name === "list") pohunek.setView(name === "state" ? "state" : "groups")
        else if (name === "help" || name === "hosts") root.page = name
        else if (name === "new") root.newSessionFrom(null)
        else if (name === "actions") {
          var first = root.items.filter(function(i) { return i.type === "row" })[0]
          if (first) { root.cursorActive = true; root.cursor = root.items.indexOf(first); root.openSheet("actions", first.row) }
        }
      })
      return "ok"
    }
  }

  // ----------------------------------------------------------- bar button
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    dimmed: pohunek.counts.state === "missing" || pohunek.counts.state === "offline"
    labelText: pohunek.counts.needs > 0 ? Commons.I18n.formatNumber(pohunek.counts.needs) : ""
    // Like the companions' tray badge: the count is the sessions that need
    // you; the icon's cursor carries the most urgent state.
    tooltipText: root.opened ? "" : root.tooltip
    iconComponent: Component {
      PromptIcon {
        size: button.iconSize
        plate: button.foreground
        cursorColor: ["needs", "problem", "working"].indexOf(pohunek.counts.state) >= 0
          ? root.stateColor(pohunek.counts.state) : "transparent"
        opacity: button.dimmed ? 0.55 : 1
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) pohunek.refresh(true)
      else if (buttonCode === Qt.MiddleButton) {
        // Straight to the session that has waited longest for you.
        var secs = Model.sections(Model.applyFilters(pohunek.rows, {}), "state", {})
        if (secs.length > 0 && secs[0].kind === "needs") pohunek.attach(secs[0].rows[0])
        else root.toggle()
      } else root.toggle()
    }
  }

  // ------------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(Style.space(660), Style.space(660))

    content: PanelKeyCatcher {
      id: keys
      property alias listFlick: listFlick
      anchors.fill: parent
      implicitHeight: Style.space(660)
      property alias newForm: newForm
      // Keys go to a text field while one has focus.
      blocked: {
        var f = Window.activeFocusItem
        return !!f && typeof f.cursorPosition === "number"
      }

      onMoveRequested: function(dx, dy) {
        if (root.sheet !== "") {
          if (dy !== 0) root.sheetCursor = Math.max(0, Math.min(sheetList.count - 1, root.sheetCursor + dy))
          return
        }
        if (root.page !== "list") { if (dx < 0) root.back(); return }
        if (dy !== 0) {
          if (!root.cursorActive) { root.cursorActive = true; return }
          root.moveCursor(dy)
        } else if (dx > 0) {
          var row = root.currentRow()
          if (row) root.openSheet("actions", row)
        } else if (dx < 0) {
          var c = root.current()
          if (c && c.type === "header" && !c.section.collapsed && c.section.kind !== "needs") pohunek.toggleCollapsed(c.section.id)
        }
      }
      onActivateRequested: {
        if (root.sheet !== "") { sheetList.activate(root.sheetCursor); return }
        if (root.page === "list" && root.cursorActive) root.activate()
      }
      onCloseRequested: root.back()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (root.sheet !== "" || root.page !== "list") return
        var row = root.currentRow()
        switch (text) {
        case "/": root.searchOpen = true; break
        case "v": pohunek.setView(root.view === "state" ? "groups" : "state"); break
        case "n": root.newSessionFrom(null); break
        case "H": root.page = "hosts"; break
        case "r": pohunek.refresh(true); break
        case "s": root.openSheet("state"); break
        case "p": root.openSheet("project"); break
        case "m": root.openSheet("menu"); break
        case "i": if (row) root.showDetails(row); break
        case "d": if (row) { pohunek.diff(row); root.close() } break
        case "o": if (row && row.workUrl) { pohunek.openLink(row); root.close() } break
        case "e": if (row) root.openSheet("rename", row); break
        case "g": if (row) root.openSheet("group", row); break
        case "c": root.clearFilters(); break
        case "?": root.page = "help"; break
        }
      }

      // ===== list page =====
      ColumnLayout {
        anchors.fill: parent
        spacing: 0
        visible: root.page === "list"

        // Header: logo, view title ▾, new session, overflow.
        RowLayout {
          Layout.fillWidth: true
          Layout.bottomMargin: Style.space(8)
          spacing: Style.space(10)

          Image {
            source: Qt.resolvedUrl("assets/pohunek-app.png")
            sourceSize.width: Style.space(28) * 2
            sourceSize.height: Style.space(28) * 2
            Layout.preferredWidth: Style.space(28)
            Layout.preferredHeight: Style.space(28)
            smooth: true
          }

          Clickable {
            Layout.fillWidth: true
            implicitHeight: viewTitle.implicitHeight + Style.space(6)
            onClicked: root.openSheet("view")
            Row {
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)
              Label {
                id: viewTitle
                text: root.view === "state" ? root.t("view.state") : root.t("view.groups")
                font.pixelSize: Style.font.heading
              }
              Label { text: "▾"; color: root.dim; font.pixelSize: Style.font.body; anchors.verticalCenter: parent.verticalCenter }
            }
          }

          PanelActionButton {
            iconText: "󰘥"
            tooltipText: root.t("help.title") + " (?)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.page = "help"
          }
          PanelActionButton {
            iconText: "󰐕"
            tooltipText: root.t("action.newSession")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.newSessionFrom(null)
          }
          PanelActionButton {
            iconText: "󰇙"
            tooltipText: root.t("menu.title")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openSheet("menu")
          }
        }

        // Banner: action feedback, then hosts that dropped off.
        Banner {
          Layout.fillWidth: true
          visible: pohunek.banner !== ""
          text: pohunek.banner
          tone: pohunek.bannerError ? root.urgent : root.foreground
        }
        Repeater {
          model: root.unreachableHosts
          Banner {
            required property var modelData
            Layout.fillWidth: true
            text: root.t("host.unreachableLine").arg(modelData.label).arg(modelData.message || modelData.error)
            tone: root.dim
          }
        }

        // Setup / offline states.
        Label {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(24)
          visible: pohunek.loaded && (pohunek.counts.state === "missing" || pohunek.counts.state === "offline")
          text: pohunek.counts.state === "missing" ? root.t("setup.notInstalled") : root.t("setup.offline")
          color: root.dim
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
        RowLayout {
          Layout.alignment: Qt.AlignHCenter
          Layout.topMargin: Style.space(10)
          visible: pohunek.loaded && (pohunek.counts.state === "missing" || pohunek.counts.state === "offline")
          spacing: Style.space(8)
          Button {
            text: pohunek.counts.state === "missing" ? root.t("setup.install") : root.t("setup.doctor")
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: { pohunek.runTool(pohunek.counts.state === "missing" ? "install-pohunek" : "doctor"); root.close() }
          }
          Button {
            text: root.t("setup.network")
            foreground: Commons.Color.accent
            fontFamily: root.fontFamily
            onClicked: { pohunek.runTool("setup-network"); root.close() }
          }
        }

        Flickable {
          id: listFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          interactive: root.sheet === "" && contentHeight > height
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: listFlick.width

            Repeater {
              model: root.items
              delegate: Loader {
                required property var modelData
                required property int index
                readonly property int itemIndex: index
                width: listColumn.width
                sourceComponent: modelData.type === "header" ? headerDelegate : rowDelegate
                onLoaded: { item.entry = modelData; item.itemIndex = index }
              }
            }

            Label {
              width: listColumn.width
              topPadding: Style.space(24)
              visible: pohunek.counts.state !== "missing" && pohunek.counts.state !== "offline" && root.visibleRows.length === 0
              text: Model.filterCount(root.filters) > 0 ? root.t("list.noMatch") : root.t("list.empty")
              color: root.dim
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }
        }

        // Bottom bar: search and the State / Project / Host chips.
        Rectangle { Layout.fillWidth: true; height: 1; color: root.hairline }
        RowLayout {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(8)
          spacing: Style.space(6)

          PanelActionButton {
            visible: !root.searchOpen
            iconText: "󰍉"
            tooltipText: root.t("filter.search")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.searchOpen = true
          }
          TextField {
            id: searchField
            visible: root.searchOpen
            Layout.fillWidth: true
            placeholderText: root.t("filter.searchPlaceholder")
            text: root.filters.query
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onVisibleChanged: if (visible) forceActiveFocus()
            onTextChanged: if (root.searchOpen) root.setFilter("query", text)
            Keys.onEscapePressed: { if (text === "") root.searchOpen = false; else text = ""; if (!root.searchOpen) root.refocus() }
            Keys.onReturnPressed: { root.searchOpen = text !== ""; root.cursorActive = true; root.cursor = 0; root.refocus() }
            Keys.onDownPressed: { root.cursorActive = true; root.refocus() }
          }
          Chip {
            visible: !root.searchOpen
            text: root.filters.states.length > 0
              ? root.t("filter.state") + "·" + Commons.I18n.formatNumber(root.filters.states.length) : root.t("filter.state")
            selected: root.filters.states.length > 0
            dropdown: true
            onClicked: root.openSheet("state")
          }
          Chip {
            visible: !root.searchOpen
            Layout.maximumWidth: Style.space(130)
            text: root.filters.project !== "" ? root.filters.project : root.t("filter.project")
            selected: root.filters.project !== ""
            dropdown: true
            onClicked: root.openSheet("project")
          }
          Chip {
            visible: !root.searchOpen && root.multiHost
            Layout.maximumWidth: Style.space(120)
            text: root.filters.host !== "" ? root.hostLabel(root.filters.host) : root.t("filter.host")
            selected: root.filters.host !== ""
            dropdown: true
            onClicked: root.openSheet("host")
          }
          Item { Layout.fillWidth: true; visible: !root.searchOpen }
          PanelActionButton {
            visible: Model.filterCount(root.filters) > 0
            iconText: "󰅖"
            tooltipText: root.t("filter.clear")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.clearFilters()
          }
        }
      }

      // ===== details page =====
      DetailsPage { anchors.fill: parent; visible: root.page === "details"; row: root.detailRow }

      // ===== help page =====
      HelpPage { anchors.fill: parent; visible: root.page === "help" }

      // ===== hosts page =====
      HostsPage { anchors.fill: parent; visible: root.page === "hosts" }

      // ===== new session page =====
      NewSessionPage { id: newForm; anchors.fill: parent; visible: root.page === "new" }

      // ===== sheets =====
      Rectangle {
        anchors.fill: parent
        visible: root.sheet !== ""
        color: Qt.rgba(Commons.Color.popups.background.r, Commons.Color.popups.background.g, Commons.Color.popups.background.b, 0.6)
        // Swallows the wheel too, so scrolling a sheet never scrolls the list behind it.
        MouseArea {
          anchors.fill: parent
          onClicked: root.closeSheet()
          onWheel: function(wheel) { wheel.accepted = true }
        }
      }
      Sheet {
        id: sheetList
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.sheet !== ""
      }
    }
  }

  function hostLabel(target) {
    for (var i = 0; i < pohunek.hosts.length; i++) if (pohunek.hosts[i].target === target) return pohunek.hosts[i].label
    return target
  }

  // =================================================================== parts

  component Label: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component Clickable: Item {
    id: clickable
    signal clicked()
    signal rightClicked()
    property bool hovered: area.containsMouse
    MouseArea {
      id: area
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) { if (mouse.button === Qt.RightButton) clickable.rightClicked(); else clickable.clicked() }
    }
  }

  component Chip: Rectangle {
    id: chip
    property string text: ""
    property bool selected: false
    property bool dropdown: false
    property color tint: root.foreground
    signal clicked()
    implicitHeight: chipLabel.implicitHeight + Style.space(10)
    implicitWidth: chipRow.implicitWidth + Style.space(20)
    Layout.preferredWidth: implicitWidth
    radius: height / 2
    color: selected ? Qt.rgba(tint.r, tint.g, tint.b, 0.22) : (chipArea.containsMouse ? root.chipFill : "transparent")
    border.width: 1
    border.color: selected ? "transparent" : Qt.rgba(tint.r, tint.g, tint.b, 0.35)
    Row {
      id: chipRow
      anchors.centerIn: parent
      width: Math.min(implicitWidth, chip.width - Style.space(16))
      spacing: Style.space(4)
      Label {
        id: chipLabel
        text: chip.text
        width: Math.min(implicitWidth, chip.width - Style.space(16) - (chip.dropdown ? Style.space(14) : 0))
        font.pixelSize: Style.font.bodySmall
        color: chip.tint
      }
      Label { visible: chip.dropdown; text: "▾"; font.pixelSize: Style.font.caption; color: root.dim; anchors.verticalCenter: parent.verticalCenter }
    }
    MouseArea { id: chipArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: chip.clicked() }
  }

  component Banner: Rectangle {
    property string text: ""
    property color tone: root.foreground
    implicitHeight: bannerLabel.implicitHeight + Style.space(10)
    color: Qt.rgba(tone.r, tone.g, tone.b, 0.10)
    radius: Style.cornerRadius
    Layout.bottomMargin: Style.space(6)
    Label {
      id: bannerLabel
      anchors.fill: parent
      anchors.margins: Style.space(5)
      anchors.leftMargin: Style.space(10)
      text: parent.text
      color: parent.tone
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      maximumLineCount: 3
      verticalAlignment: Text.AlignVCenter
    }
  }

  // The pohunek plate with its ">_" prompt cut out (the app icon at bar
  // size). Only the cursor carries the state: amber when a session needs
  // you, red on a runtime problem, green while agents work; at rest it is
  // cut out like the chevron. Drawn as vectors, so it stays crisp at 12 px.
  component PromptIcon: Item {
    id: icon
    property real size: Style.bar.iconSize
    property color plate: root.foreground
    property color cursorColor: "transparent"
    readonly property real u: size / 16
    implicitWidth: size
    implicitHeight: size

    // Chevron and cursor in white: the inverted mask that cuts the plate.
    Item {
      id: cutouts
      anchors.fill: parent
      visible: false
      layer.enabled: true
      layer.samples: 4
      Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
          strokeColor: "white"; fillColor: "transparent"; strokeWidth: 1.7 * icon.u
          capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
          startX: 4.3 * icon.u; startY: 5.2 * icon.u
          PathLine { x: 7.1 * icon.u; y: 8 * icon.u }
          PathLine { x: 4.3 * icon.u; y: 10.8 * icon.u }
        }
        ShapePath {
          strokeColor: "white"; fillColor: "transparent"; strokeWidth: 1.8 * icon.u
          capStyle: ShapePath.RoundCap
          startX: 8.7 * icon.u; startY: 10.9 * icon.u
          PathLine { x: 12 * icon.u; y: 10.9 * icon.u }
        }
      }
    }

    Item {
      anchors.fill: parent
      layer.enabled: true
      layer.effect: MultiEffect {
        maskEnabled: true
        maskInverted: true
        maskSource: cutouts
        maskThresholdMin: 0.0
        maskSpreadAtMin: 0.0
      }
      Rectangle {
        x: 1 * icon.u; y: 1.5 * icon.u
        width: 14 * icon.u; height: 13 * icon.u
        radius: 3.3 * icon.u
        color: icon.plate
        antialiasing: true
      }
    }

    // The state, painted into the cursor's slot.
    Shape {
      anchors.fill: parent
      visible: icon.cursorColor.a > 0
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        strokeColor: icon.cursorColor; fillColor: "transparent"; strokeWidth: 2.1 * icon.u
        capStyle: ShapePath.RoundCap
        startX: 8.7 * icon.u; startY: 10.9 * icon.u
        PathLine { x: 12 * icon.u; y: 10.9 * icon.u }
      }
    }
  }

  Component {
    id: headerDelegate
    Clickable {
      id: header
      property var entry: null
      property int itemIndex: -1
      readonly property var sec: entry ? entry.section : null
      readonly property bool hasCursor: root.cursorActive && root.cursor === itemIndex
      width: parent ? parent.width : 0
      implicitHeight: headerRow.implicitHeight + Style.space(sec && sec.kind === "needs" ? 14 : 18)
      onClicked: { root.cursor = itemIndex; if (sec && sec.kind !== "needs") pohunek.toggleCollapsed(sec.id) }
      onRightClicked: if (sec && sec.kind === "group" && !sec.inbox && sec.count === 0) pohunek.removeGroup(sec.name)

      Rectangle { anchors.fill: parent; color: header.hasCursor || header.hovered ? root.chipFill : "transparent"; radius: Style.cornerRadius }
      Rectangle { visible: header.sec && header.sec.kind !== "needs" && header.itemIndex > 0; width: parent.width; height: 1; color: root.hairline }

      RowLayout {
        id: headerRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(4)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(10)
        Label {
          visible: header.sec && header.sec.kind !== "needs"
          text: header.sec && header.sec.collapsed ? "›" : "⌄"
          font.pixelSize: Style.font.heading
          Layout.preferredWidth: Style.space(14)
          horizontalAlignment: Text.AlignHCenter
        }
        Label {
          Layout.fillWidth: true
          text: header.sec ? root.sectionTitle(header.sec) : ""
          font.pixelSize: header.sec && header.sec.kind === "needs" ? Style.font.body : Style.font.body
          font.weight: Font.DemiBold
          color: header.sec && header.sec.kind === "state" ? root.stateColor(header.sec.state) : root.foreground
        }
        Label {
          visible: header.sec && header.sec.kind !== "needs"
          text: header.sec ? Commons.I18n.formatNumber(header.sec.count) : ""
          color: root.dim
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }

  Component {
    id: rowDelegate
    Clickable {
      id: rowItem
      property var entry: null
      property int itemIndex: -1
      readonly property var row: entry ? entry.row : null
      readonly property bool hasCursor: root.cursorActive && root.cursor === itemIndex
      width: parent ? parent.width : 0
      implicitHeight: rowCol.implicitHeight + Style.space(16)
      opacity: row && row.stale ? 0.45 : 1
      onClicked: { root.cursor = itemIndex; root.attachRow(row) }
      onRightClicked: { root.cursor = itemIndex; root.openSheet("actions", row) }

      Rectangle {
        anchors.fill: parent
        radius: Style.cornerRadius
        color: rowItem.hasCursor ? Style.selectedFillFor(root.foreground, Commons.Color.accent, root.urgent)
             : rowItem.hovered ? root.chipFill : "transparent"
      }
      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.hairline }

      Rectangle {
        id: dot
        x: Style.space(6)
        y: Style.space(10) + (titleLabel.implicitHeight - height) / 2
        width: Style.space(8); height: width; radius: width / 2
        color: rowItem.row ? root.stateColor(rowItem.row.ownerState) : root.dim
      }

      Column {
        id: rowCol
        anchors.left: dot.right
        anchors.leftMargin: Style.space(12)
        anchors.right: trailing.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Label {
          id: titleLabel
          width: parent.width
          text: rowItem.row ? rowItem.row.title : ""
          font.pixelSize: Style.font.body
        }
        Row {
          width: parent.width
          spacing: 0
          Label {
            text: rowItem.row ? root.stateLabel(rowItem.row.ownerState) : ""
            color: rowItem.row ? root.stateColor(rowItem.row.ownerState) : root.dim
            font.pixelSize: Style.font.bodySmall
          }
          Label {
            width: Math.max(0, parent.width - x)
            text: {
              var r = rowItem.row
              if (!r) return ""
              var parts = [r.agent]
              if (r.ownerState === "needs" && r.waitingSince) parts.push(root.ageText(r.waitingSince))
              if (r.subagentsRunning > 0) parts.push(strings.tn("subagents", r.subagentsRunning).arg(Commons.I18n.formatNumber(r.subagentsRunning)))
              return " · " + parts.filter(function(p) { return p }).join(" · ")
            }
            color: root.dim
            font.pixelSize: Style.font.bodySmall
          }
        }
        Label {
          width: parent.width
          visible: text !== ""
          text: {
            var r = rowItem.row
            if (!r) return ""
            var parts = [r.project, r.badge, r.ownerState === "ended" && r.lossCause ? r.lossCause : r.branch]
            return parts.filter(function(p) { return p }).join(" · ")
          }
          color: root.dim
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        id: trailing
        anchors.right: parent.right
        anchors.rightMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)
        Chip {
          visible: root.multiHost && rowItem.row
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, Style.space(110))
          text: rowItem.row ? rowItem.row.hostLabel : ""
          color: root.chipFill
          border.width: 0
          onClicked: { root.cursor = rowItem.itemIndex; root.attachRow(rowItem.row) }
        }
        PanelActionButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "󰇙"
          foreground: root.dim
          hoverColor: root.foreground
          fontFamily: root.fontFamily
          onClicked: { root.cursor = rowItem.itemIndex; root.openSheet("actions", rowItem.row) }
        }
      }
    }
  }

  // Bottom sheet: one list of options per sheet kind, keyboard and mouse.
  component Sheet: Rectangle {
    id: sheetRoot
    readonly property var options: buildOptions()
    property alias count: optionRepeater.count
    implicitHeight: Math.min(sheetColumn.implicitHeight + Style.space(20), (parent ? parent.height : 600) * 0.85)
    color: Commons.Color.popups.background
    border.width: 1
    border.color: root.hairline
    radius: Math.max(Style.cornerRadius, Style.space(12))

    MouseArea {
      anchors.fill: parent
      onWheel: function(wheel) { wheel.accepted = true }
    }

    function activate(index) {
      var opt = options[index]
      if (opt && opt.enabled !== false && typeof opt.run === "function") opt.run()
    }

    readonly property bool searchable: (root.sheet === "project" || root.sheet === "host" || root.sheet === "group")
      && pickerParts(root.sheet, root.sheetRow).choices.length > Model.FUZZY_THRESHOLD

    function pickerParts(kind, row) {
      var head = [], choices = [], tail = []
      if (kind === "project") {
        head.push({ label: root.t("filter.allProjects"), checked: root.filters.project === "", run: function() { root.setFilter("project", ""); root.closeSheet() } })
        var seen = {}
        var recent = root.projectChoices.recent
        root.projectChoices.recent.concat(root.projectChoices.all).forEach(function(name) {
          if (seen[name]) return
          seen[name] = true
          choices.push({ label: name, detail: recent.indexOf(name) >= 0 ? root.t("picker.recent") : "", checked: root.filters.project === name,
                         run: function() { root.setFilter("project", name); pohunek.rememberProject(name); root.closeSheet() } })
        })
      } else if (kind === "host") {
        head.push({ label: root.t("filter.allHosts"), checked: root.filters.host === "", run: function() { root.setFilter("host", ""); root.closeSheet() } })
        pohunek.hosts.forEach(function(h) {
          choices.push({ label: h.label, detail: h.reachable ? "" : root.t("host.unreachable"), checked: root.filters.host === h.target,
                         run: function() { root.setFilter("host", h.target); root.closeSheet() } })
        })
      } else if (kind === "group" && row) {
        root.groupChoices.forEach(function(g) {
          var isInbox = g.toLowerCase() === "inbox"
          choices.push({ label: isInbox ? root.t("group.inbox") : g, checked: row.group.toLowerCase() === g.toLowerCase(),
                         run: function() { pohunek.moveToGroup(row, g); root.closeSheet() } })
        })
        tail.push({ label: root.t("menu.newGroup"), run: function() { root.openSheet("newGroup", row) } })
      }
      return { head: head, choices: choices, tail: tail }
    }

    function buildOptions() {
      var row = root.sheetRow
      var out = []
      switch (root.sheet) {
      case "actions":
        if (!row) return out
        if (row.ownerState === "ended") {
          if (row.resumable) out.push({ label: root.t("action.resume"), run: function() { pohunek.resume(row); root.closeSheet(); root.close() } })
        } else out.push({ label: root.t("action.openTerminal"), run: function() { root.closeSheet(); root.attachRow(row) } })
        out.push({ label: root.t("action.details"), run: function() { root.showDetails(row) } })
        out.push({ label: root.t("action.rename"), run: function() { root.openSheet("rename", row) } })
        out.push({ label: root.t("action.newHere"), run: function() { root.newSessionFrom(row) } })
        out.push({ label: root.t("action.moveToGroup"), run: function() { root.openSheet("group", row) } })
        if (row.workUrl) out.push({ label: root.t("action.openLink"), detail: row.badge, run: function() { pohunek.openLink(row); root.closeSheet(); root.close() } })
        if (row.ownerState !== "ended") out.push({ label: root.t("action.diff"), run: function() { pohunek.diff(row); root.closeSheet(); root.close() } })
        out.push({ label: root.t("action.copyId"), detail: row.target, run: function() { pohunek.copy(row.target); root.closeSheet() } })
        if (row.ownerState !== "ended") out.push({ label: root.t("action.stop"), destructive: true, run: function() { root.confirmAction = "stop"; root.sheet = "confirm"; root.sheetCursor = 0 } })
        out.push({ label: root.t("action.remove"), destructive: true, run: function() { root.confirmAction = "remove"; root.sheet = "confirm"; root.sheetCursor = 0 } })
        return out
      case "confirm":
        out.push({ label: root.t("confirm.cancel"), run: function() { root.openSheet("actions", row) } })
        out.push({ label: root.confirmAction === "stop" ? root.t("confirm.stop") : root.t("confirm.remove"), destructive: true,
                   run: function() { if (root.confirmAction === "stop") pohunek.stop(row); else pohunek.remove(row); root.closeSheet() } })
        return out
      case "view":
        out.push({ label: root.t("view.groups"), checked: root.view === "groups", run: function() { pohunek.setView("groups"); root.closeSheet() } })
        out.push({ label: root.t("view.state"), checked: root.view === "state", run: function() { pohunek.setView("state"); root.closeSheet() } })
        return out
      case "menu":
        out.push({ label: root.t("action.newSession"), detail: "n", run: function() { root.newSessionFrom(null) } })
        out.push({ label: root.t("menu.newGroup"), run: function() { root.openSheet("newGroup") } })
        out.push({ label: root.t("menu.hosts"), detail: "H", run: function() { root.page = "hosts"; root.closeSheet() } })
        out.push({ label: root.t("menu.assistant"), run: function() { pohunek.assistant(root.filters.host); root.closeSheet(); root.close() } })
        out.push({ label: root.t("menu.refresh"), detail: "r", run: function() { pohunek.refresh(true); root.closeSheet() } })
        out.push({ label: root.t("help.title"), detail: "?", run: function() { root.page = "help"; root.closeSheet() } })
        out.push({ label: "pohunek.dev", detail: "↗", run: function() { pohunek.openWeb("site"); root.closeSheet(); root.close() } })
        return out
      case "state":
        var states = ["needs", "working", "idle", "problem", "nostate", "ended"]
        for (var i = 0; i < states.length; i++) (function(s) {
          out.push({ label: root.stateLabel(s), color: root.stateColor(s), checked: root.filters.states.indexOf(s) >= 0,
                     run: function() { root.toggleState(s) } })
        })(states[i])
        return out
      case "project": case "host": case "group":
        // Pickers: a fixed head ("All …"), the choices, a fixed tail ("New
        // group…"). Past FUZZY_THRESHOLD choices the sheet gets a fuzzy
        // search field and only the ranked matches are shown.
        var p = pickerParts(root.sheet, row)
        var q = root.pickerQuery.trim()
        if (searchable && q !== "") return Model.fuzzyFilter(p.choices, q, 60)
        return p.head.concat(p.choices).concat(p.tail)
      }
      return out
    }

    ColumnLayout {
      id: sheetColumn
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: Style.space(4)

      Rectangle { Layout.alignment: Qt.AlignHCenter; width: Style.space(32); height: Style.space(4); radius: 2; color: root.dim }

      Label {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        Layout.bottomMargin: Style.space(4)
        text: {
          switch (root.sheet) {
          case "actions": case "group": case "rename": return root.sheetRow ? root.sheetRow.title : ""
          case "confirm": return (root.confirmAction === "stop" ? root.t("confirm.stopQuestion") : root.t("confirm.removeQuestion"))
            .arg(root.sheetRow ? root.sheetRow.title : "")
          case "view": return root.t("view.title")
          case "menu": return root.t("menu.title")
          case "state": return root.t("filter.state")
          case "project": return root.t("filter.project")
          case "host": return root.t("filter.host")
          case "newGroup": return root.t("menu.newGroup")
          }
          return ""
        }
        font.weight: Font.DemiBold
        wrapMode: Text.WordWrap
      }

      // Text sheets: rename, new group, project search.
      TextField {
        id: sheetField
        Layout.fillWidth: true
        visible: root.sheet === "rename" || root.sheet === "newGroup" || sheetRoot.searchable
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        placeholderText: root.sheet === "rename" ? root.t("rename.placeholder")
                       : root.sheet === "newGroup" ? root.t("group.namePlaceholder") : root.t("picker.search")
        // Reset whenever another sheet takes the field (project → host keeps it visible).
        readonly property string forSheet: visible ? root.sheet : ""
        onForSheetChanged: if (visible) {
          text = root.sheet === "rename" && root.sheetRow ? root.sheetRow.name : ""
          forceActiveFocus()
          selectAll()
        }
        onTextChanged: if (sheetRoot.searchable) { root.pickerQuery = text; root.sheetCursor = 0 }
        Keys.onEscapePressed: root.closeSheet()
        Keys.onDownPressed: if (sheetRoot.searchable) root.sheetCursor = Math.min(optionRepeater.count - 1, root.sheetCursor + 1)
        Keys.onUpPressed: if (sheetRoot.searchable) root.sheetCursor = Math.max(0, root.sheetCursor - 1)
        Keys.onReturnPressed: sheetRoot.submitText()
        Keys.onEnterPressed: sheetRoot.submitText()
      }
      RowLayout {
        Layout.fillWidth: true
        visible: root.sheet === "rename" || root.sheet === "newGroup"
        Item { Layout.fillWidth: true }
        Button {
          text: root.t("confirm.cancel")
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.closeSheet()
        }
        Button {
          text: root.sheet === "rename" ? root.t("rename.save") : root.t("group.create")
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          onClicked: sheetRoot.submitText()
        }
      }

      Flickable {
        Layout.fillWidth: true
        Layout.preferredHeight: Math.min(optionColumn.implicitHeight, Style.space(380))
        visible: optionRepeater.count > 0
        contentHeight: optionColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        Column {
          id: optionColumn
          width: parent.width
          Repeater {
            id: optionRepeater
            model: (root.sheet === "rename" || root.sheet === "newGroup") ? [] : sheetRoot.options
            Clickable {
              id: option
              required property var modelData
              required property int index
              width: optionColumn.width
              implicitHeight: optLabel.implicitHeight + Style.space(18)
              onClicked: sheetRoot.activate(index)
              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: root.sheetCursor === option.index ? Style.selectedFillFor(root.foreground, Commons.Color.accent, root.urgent)
                     : option.hovered ? root.chipFill : "transparent"
              }
              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)
                Rectangle {
                  visible: option.modelData.color !== undefined
                  width: Style.space(8); height: width; radius: width / 2
                  color: option.modelData.color || "transparent"
                }
                Label {
                  id: optLabel
                  Layout.fillWidth: true
                  text: option.modelData.label
                  color: option.modelData.destructive ? root.urgent : root.foreground
                }
                Label { visible: !!option.modelData.detail; text: option.modelData.detail || ""; color: root.dim; font.pixelSize: Style.font.bodySmall; Layout.maximumWidth: Style.space(180) }
                Label { visible: !!option.modelData.checked; text: "󰄬"; color: Commons.Color.accent }
              }
            }
          }
        }
      }
    }

    function submitText() {
      if (searchable) { activate(root.sheetCursor); return }
      var value = sheetField.text
      var row = root.sheetRow
      if (root.sheet === "rename") { pohunek.rename(row, value); root.closeSheet(); return }
      if (root.sheet === "newGroup") {
        var checked = pohunek.addGroup(value)
        if (!checked.ok) { pohunek.say(root.t("group.invalid." + checked.problem), true); return }
        if (row) pohunek.moveToGroup(row, checked.name)
        root.closeSheet()
      }
    }
  }

  // Choice control: chips while the list is short, past FUZZY_THRESHOLD a
  // select box that opens a fuzzy search field over the ranked matches
  // (↑↓ move, Enter picks, Esc closes).
  component Picker: ColumnLayout {
    id: picker
    property var options: []          // [{ value, label, detail? }]
    property string value: ""
    property string placeholder: ""
    property string emptyLabel: ""    // optional choice with value ""
    property bool expanded: false
    property string query: ""
    property int cursor: 0
    signal picked(string value)

    readonly property bool fuzzy: options.length > Model.FUZZY_THRESHOLD
    readonly property var allChoices: emptyLabel !== "" ? [{ value: "", label: emptyLabel }].concat(options) : options
    readonly property var matches: query.trim() === "" ? allChoices.slice(0, 60) : Model.fuzzyFilter(options, query, 60)
    readonly property string currentLabel: {
      for (var i = 0; i < allChoices.length; i++) if (allChoices[i].value === value) return allChoices[i].label
      return value
    }
    spacing: Style.space(4)

    function choose(v) {
      expanded = false
      query = ""
      picked(v)
    }
    function open() {
      expanded = true
      query = ""
      cursor = 0
      for (var i = 0; i < matches.length; i++) if (matches[i].value === value) { cursor = i; break }
      Qt.callLater(function() { searchBox.forceActiveFocus() })
    }
    onMatchesChanged: if (cursor >= matches.length) cursor = Math.max(0, matches.length - 1)

    // Short lists: chips.
    Flow {
      Layout.fillWidth: true
      visible: !picker.fuzzy
      spacing: Style.space(6)
      Repeater {
        model: picker.fuzzy ? [] : picker.allChoices
        Chip {
          required property var modelData
          text: modelData.label
          selected: picker.value === modelData.value
          onClicked: picker.choose(modelData.value)
        }
      }
    }

    // Long lists: select box …
    Rectangle {
      Layout.fillWidth: true
      visible: picker.fuzzy && !picker.expanded
      implicitHeight: selectLabel.implicitHeight + Style.space(14)
      radius: Style.cornerRadius
      color: selectArea.containsMouse ? root.chipFill : "transparent"
      border.width: 1
      border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.35)
      Label {
        id: selectLabel
        anchors.left: parent.left
        anchors.right: caret.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: picker.currentLabel !== "" ? picker.currentLabel : picker.placeholder
        color: picker.currentLabel !== "" ? root.foreground : root.dim
      }
      Label {
        id: caret
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: Commons.I18n.formatNumber(picker.options.length) + "  ▾"
        color: root.dim
        font.pixelSize: Style.font.caption
      }
      MouseArea { id: selectArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: picker.open() }
    }

    // … that opens into a fuzzy search over the ranked matches.
    TextField {
      id: searchBox
      Layout.fillWidth: true
      visible: picker.fuzzy && picker.expanded
      placeholderText: root.t("picker.search")
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      text: picker.query
      onTextChanged: { picker.query = text; picker.cursor = 0 }
      Keys.onDownPressed: picker.cursor = Math.min(picker.matches.length - 1, picker.cursor + 1)
      Keys.onUpPressed: picker.cursor = Math.max(0, picker.cursor - 1)
      Keys.onReturnPressed: if (picker.matches.length > 0) picker.choose(picker.matches[picker.cursor].value)
      Keys.onEnterPressed: if (picker.matches.length > 0) picker.choose(picker.matches[picker.cursor].value)
      Keys.onEscapePressed: { picker.expanded = false; picker.query = "" }
      Keys.onTabPressed: picker.expanded = false
    }
    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: Math.min(matchColumn.implicitHeight, Style.space(220)) + 2
      visible: picker.fuzzy && picker.expanded
      radius: Style.cornerRadius
      color: "transparent"
      border.width: 1
      border.color: root.hairline
      Flickable {
        id: matchFlick
        anchors.fill: parent
        anchors.margins: 1
        contentHeight: matchColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        Column {
          id: matchColumn
          width: matchFlick.width
          Repeater {
            model: picker.expanded ? picker.matches : []
            Clickable {
              id: match
              required property var modelData
              required property int index
              width: matchColumn.width
              implicitHeight: matchLabel.implicitHeight + Style.space(12)
              onClicked: picker.choose(modelData.value)
              onHoveredChanged: if (hovered) picker.cursor = index
              Rectangle {
                anchors.fill: parent
                color: picker.cursor === match.index ? Style.selectedFillFor(root.foreground, Commons.Color.accent, root.urgent) : "transparent"
              }
              Label {
                id: matchLabel
                anchors.left: parent.left
                anchors.right: check.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: match.modelData.label
              }
              Label {
                id: check
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: picker.value === match.modelData.value ? "󰄬" : ""
                color: Commons.Color.accent
              }
            }
          }
          Label {
            visible: picker.matches.length === 0
            width: matchColumn.width
            padding: Style.space(10)
            text: root.t("picker.noMatch")
            color: root.dim
          }
        }
      }
    }
    // Keep the highlighted match in view while moving with the keys.
    onCursorChanged: {
      var rowH = matchColumn.children.length > 0 ? matchColumn.children[0].height : 0
      if (rowH <= 0) return
      var top = cursor * rowH
      if (top < matchFlick.contentY) matchFlick.contentY = top
      else if (top + rowH > matchFlick.contentY + matchFlick.height) matchFlick.contentY = top + rowH - matchFlick.height
    }
  }

  component PageHeader: RowLayout {
    property string title: ""
    property Component trailing: null
    spacing: Style.space(10)
    Layout.fillWidth: true
    Layout.bottomMargin: Style.space(10)
    Button {
      text: root.t("nav.back")
      foreground: Commons.Color.accent
      fontFamily: root.fontFamily
      onClicked: root.back()
    }
    Label { Layout.fillWidth: true; text: parent.title; font.pixelSize: Style.font.heading }
    Loader { sourceComponent: parent.trailing }
  }

  component DetailsPage: Item {
    id: details
    property var row: null
    readonly property var fields: {
      var r = row
      if (!r) return []
      var f = []
      function add(section, label, value) { if (value !== "" && value !== undefined && value !== null) f.push({ section: section, label: label, value: String(value) }) }
      add(root.t("details.identity"), root.t("details.sessionId"), r.id)
      add(root.t("details.identity"), root.t("details.target"), r.target)
      add(root.t("details.identity"), root.t("details.name"), r.name)
      add(root.t("details.identity"), root.t("details.host"), r.hostLabel)
      add(root.t("details.agent"), root.t("details.agent"), r.agent)
      add(root.t("details.agent"), root.t("details.profile"), r.profile)
      add(root.t("details.agent"), root.t("details.ownerState"), root.stateLabel(r.ownerState))
      add(root.t("details.agent"), root.t("details.state"), [r.state, r.activity, r.runtimeState].filter(function(p) { return p }).join(" · "))
      if (r.waitingSince) add(root.t("details.agent"), root.t("details.waitingSince"), new Date(r.waitingSince).toLocaleString(Qt.locale(Commons.I18n.formatLocale), Locale.ShortFormat))
      add(root.t("details.agent"), root.t("details.lossCause"), r.lossCause)
      add(root.t("details.location"), root.t("details.cwd"), r.cwd)
      add(root.t("details.location"), root.t("details.project"), r.project)
      add(root.t("details.location"), root.t("details.branch"), r.branch)
      add(root.t("details.location"), root.t("details.worktree"), r.worktree)
      add(root.t("details.work"), root.t("details.link"), r.badge)
      add(root.t("details.work"), root.t("details.url"), r.workUrl)
      add(root.t("details.work"), root.t("details.role"), r.role)
      add(root.t("details.work"), root.t("details.group"), r.group)
      return f
    }

    ColumnLayout {
      anchors.fill: parent
      spacing: 0
      PageHeader {
        title: details.row ? details.row.title : ""
        trailing: Component {
          Button {
            text: root.t("details.copyAll")
            foreground: Commons.Color.accent
            fontFamily: root.fontFamily
            onClicked: pohunek.copy(details.fields.map(function(f) { return f.label + ": " + f.value }).join("\n"))
          }
        }
      }
      Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentHeight: detailCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        Column {
          id: detailCol
          width: parent.width
          Repeater {
            model: details.fields
            Column {
              required property var modelData
              required property int index
              width: detailCol.width
              Label {
                visible: index === 0 || details.fields[index - 1].section !== modelData.section
                topPadding: Style.space(12)
                bottomPadding: Style.space(4)
                text: modelData.section
                font.weight: Font.DemiBold
              }
              Item {
                width: parent.width
                implicitHeight: fieldCol.implicitHeight + Style.space(12)
                Column {
                  id: fieldCol
                  anchors.left: parent.left
                  anchors.right: copyButton.left
                  anchors.verticalCenter: parent.verticalCenter
                  Label { text: modelData.label; color: root.dim; font.pixelSize: Style.font.caption }
                  Label { width: parent.width; text: modelData.value; wrapMode: Text.WrapAnywhere; elide: Text.ElideNone; maximumLineCount: 4 }
                }
                Button {
                  id: copyButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.t("details.copy")
                  foreground: Commons.Color.accent
                  fontFamily: root.fontFamily
                  onClicked: pohunek.copy(modelData.value)
                }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.hairline }
              }
            }
          }
        }
      }
      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(8)
        visible: details.row !== null
        Item { Layout.fillWidth: true }
        Button {
          visible: details.row && details.row.ownerState !== "ended"
          text: root.t("action.openTerminal")
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.attachRow(details.row)
        }
        Button {
          visible: details.row && details.row.resumable
          text: root.t("action.resume")
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: { pohunek.resume(details.row); root.close() }
        }
      }
    }
  }

  // One simple page of everything that is easy to miss: the keys inside an
  // attached terminal, the Omarchy shortcuts, the panel keys, what the colours
  // mean, and where to read more.
  component HelpPage: Item {
    id: help
    readonly property var sections: [
      { title: root.t("help.terminal"), note: root.t("help.terminalNote"), keys: [
        { keys: ["Ctrl", "]"], text: root.t("help.detach") },
        { keys: ["Ctrl", "\\"], text: root.t("help.menu") },
        { keys: ["k", "y"], text: root.t("help.menuKill"), indent: true },
        { keys: ["t", "y"], text: root.t("help.menuTerminate"), indent: true },
        { keys: ["d"], text: root.t("help.menuDetach"), indent: true },
        { keys: ["n"], text: root.t("help.menuNew"), indent: true },
        { keys: ["r"], text: root.t("help.menuRename"), indent: true } ] },
      { title: root.t("help.omarchy"), keys: [
        { keys: ["Super", "Alt", "P"], text: root.t("help.openWidget") },
        { keys: ["Super", "Shift", "Alt", "P"], text: root.t("help.newSession") },
        { keys: [root.t("help.click")], text: root.t("help.clickText") },
        { keys: [root.t("help.middleClick")], text: root.t("help.middleClickText") },
        { keys: [root.t("help.rightClick")], text: root.t("help.rightClickText") } ] },
      { title: root.t("help.panel"), keys: [
        { keys: ["↑", "↓"], text: root.t("help.move") },
        { keys: ["Enter"], text: root.t("help.enter") },
        { keys: ["→"], text: root.t("help.actions") },
        { keys: ["/"], text: root.t("filter.search") },
        { keys: ["s", "p"], text: root.t("help.filters") },
        { keys: ["v"], text: root.t("help.view") },
        { keys: ["n"], text: root.t("action.newSession") },
        { keys: ["i", "d", "o"], text: root.t("help.rowKeys") },
        { keys: ["e", "g"], text: root.t("help.editKeys") },
        { keys: ["H"], text: root.t("menu.hosts") },
        { keys: ["c"], text: root.t("filter.clear") },
        { keys: ["r"], text: root.t("menu.refresh") },
        { keys: ["Ctrl", "Enter"], text: root.t("help.startSession") },
        { keys: ["Esc"], text: root.t("help.back") } ] }
    ]

    ColumnLayout {
      anchors.fill: parent
      spacing: 0
      PageHeader { title: root.t("help.title") }
      Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentHeight: helpCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        Column {
          id: helpCol
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: help.sections
            Column {
              required property var modelData
              width: helpCol.width
              spacing: Style.space(3)
              Label { topPadding: Style.space(10); text: modelData.title; font.weight: Font.DemiBold }
              Label {
                visible: !!modelData.note
                width: parent.width
                text: modelData.note || ""
                color: root.dim
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                elide: Text.ElideNone
                bottomPadding: Style.space(2)
              }
              Repeater {
                model: modelData.keys
                RowLayout {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(10)
                  Row {
                    Layout.preferredWidth: Style.space(150)
                    Layout.leftMargin: modelData.indent ? Style.space(18) : 0
                    spacing: Style.space(3)
                    Repeater {
                      model: modelData.keys
                      Rectangle {
                        required property var modelData
                        implicitWidth: Math.max(keyLabel.implicitWidth + Style.space(10), height)
                        implicitHeight: keyLabel.implicitHeight + Style.space(4)
                        radius: Math.max(Style.cornerRadius, Style.space(4))
                        color: root.chipFill
                        border.width: 1
                        border.color: root.hairline
                        Label { id: keyLabel; anchors.centerIn: parent; text: modelData; font.pixelSize: Style.font.bodySmall }
                      }
                    }
                  }
                  Label {
                    Layout.fillWidth: true
                    text: modelData.text
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    elide: Text.ElideNone
                  }
                }
              }
            }
          }

          Button {
            visible: !pohunek.shortcutsBound
            text: root.t("help.addShortcuts")
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: { pohunek.runTool("add-shortcuts"); root.close() }
          }

          // What the colours mean.
          Label { topPadding: Style.space(10); text: root.t("help.states"); font.weight: Font.DemiBold }
          Repeater {
            model: ["needs", "working", "idle", "problem", "ended"]
            RowLayout {
              required property var modelData
              width: helpCol.width
              spacing: Style.space(10)
              Rectangle { width: Style.space(8); height: width; radius: width / 2; color: root.stateColor(modelData) }
              Label { text: root.stateLabel(modelData); color: root.stateColor(modelData); font.pixelSize: Style.font.bodySmall; Layout.preferredWidth: Style.space(130) }
              Label { Layout.fillWidth: true; text: root.t("help.state." + modelData); color: root.dim; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap; elide: Text.ElideNone }
            }
          }
          Label {
            width: helpCol.width
            topPadding: Style.space(4)
            text: root.t("help.iconNote")
            color: root.dim
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            elide: Text.ElideNone
          }

          // Where to read more.
          Label { topPadding: Style.space(10); text: root.t("help.more"); font.weight: Font.DemiBold }
          Flow {
            width: helpCol.width
            spacing: Style.space(6)
            Repeater {
              model: [
                { key: "site", label: "pohunek.dev" },
                { key: "docs", label: root.t("help.docs") },
                { key: "surfaces", label: root.t("help.surfaces") },
                { key: "source", label: "GitHub" }
              ]
              Chip {
                required property var modelData
                text: modelData.label + " ↗"
                onClicked: { pohunek.openWeb(modelData.key); root.close() }
              }
            }
          }
          Item { width: 1; height: Style.space(8) }
        }
      }
    }
  }

  component HostsPage: Item {
    ColumnLayout {
      anchors.fill: parent
      spacing: 0
      PageHeader { title: root.t("menu.hosts") }
      Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentHeight: hostCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
          id: hostCol
          width: parent.width
          Repeater {
            model: pohunek.hosts
            Clickable {
              id: hostRow
              required property var modelData
              width: hostCol.width
              implicitHeight: hostInfo.implicitHeight + Style.space(18)
              onClicked: { root.setFilter("host", modelData.target); root.page = "list" }
              Rectangle { anchors.fill: parent; color: hostRow.hovered ? root.chipFill : "transparent"; radius: Style.cornerRadius }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: root.hairline }
              Column {
                id: hostInfo
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                Label { text: modelData.label + (modelData.local ? " (" + root.t("host.thisMachine") + ")" : "") }
                Label {
                  text: [modelData.target === "local" ? "local" : modelData.target, root.t("host.source." + modelData.source)].join(" · ")
                  color: root.dim
                  font.pixelSize: Style.font.bodySmall
                }
                Label {
                  width: parent.width
                  text: modelData.reachable
                    ? root.t("host.connected").arg(Commons.I18n.formatNumber(modelData.count)).arg(Commons.I18n.formatNumber(modelData.latencyMs))
                    : root.t("host.unreachableLine").arg(root.t("host.unreachable")).arg(modelData.message || modelData.error)
                  color: modelData.reachable ? root.stateColor("working") : root.urgent
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }
            }
          }
        }
      }
      // The overlay that carries pohunek between machines.
      Rectangle { Layout.fillWidth: true; Layout.topMargin: Style.space(8); height: 1; color: root.hairline }
      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(8)
        spacing: Style.space(8)
        Label {
          Layout.fillWidth: true
          text: root.t("network.line").arg(pohunek.overlay === "tailscale" ? "Tailscale" : pohunek.overlay === "netbird" ? "NetBird" : "?")
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          text: root.t("setup.network")
          foreground: Commons.Color.accent
          fontFamily: root.fontFamily
          onClicked: { pohunek.runTool("setup-network"); root.close() }
        }
      }

      // Omarchy's machines (herdr registry) that do not run pohunek yet.
      Label {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(10)
        visible: pohunek.machinesWithoutPohunek.length > 0
        text: root.t("machines.title")
        font.weight: Font.DemiBold
      }
      Repeater {
        model: pohunek.machinesWithoutPohunek
        RowLayout {
          required property var modelData
          Layout.fillWidth: true
          spacing: Style.space(8)
          Label {
            Layout.fillWidth: true
            text: modelData.label + (modelData.label !== modelData.target ? "  ·  " + modelData.target : "") + (modelData.enabled ? "" : "  (" + root.t("machines.disabled") + ")")
            font.pixelSize: Style.font.bodySmall
          }
          Button {
            text: root.t("machines.install")
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: { pohunek.runTool("distribute", modelData.target); root.close() }
          }
        }
      }
      Button {
        Layout.alignment: Qt.AlignRight
        visible: pohunek.machinesWithoutPohunek.length > 1
        text: root.t("machines.installAll")
        foreground: Commons.Color.accent
        fontFamily: root.fontFamily
        onClicked: { pohunek.runTool("distribute"); root.close() }
      }

      Label {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(8)
        text: root.t("host.howToAdd")
        color: root.dim
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
      }
    }
  }

  component NewSessionPage: Item {
    id: form
    property string host: "local"
    property string project: ""
    property string agent: ""
    property string group: ""

    function reset(h, p, g) {
      host = h || "local"; project = p || ""; group = g || ""; agent = ""
      nameField.text = ""; branchField.text = ""; promptField.text = ""
      pohunek.loadForm(host)
      Qt.callLater(function() { promptField.forceActiveFocus() })
    }
    function submit() {
      pohunek.newSession({ host: host, project: projectId(), agent: agent, name: nameField.text.trim(),
                           branch: branchField.text.trim(), prompt: promptField.text, group: group })
      root.close()
    }
    function projectId() {
      var ps = pohunek.form.projects
      for (var i = 0; i < ps.length; i++) if (ps[i].label === project || ps[i].id === project) return ps[i].id
      return ""
    }
    readonly property var agentChoices: {
      var list = pohunek.form.agents.slice()
      // The agents used most on this host first.
      var seen = {}
      pohunek.rows.forEach(function(r) { if (r.host === form.host) seen[r.agent] = (seen[r.agent] || 0) + 1 })
      list.sort(function(a, b) { return (seen[b] || 0) - (seen[a] || 0) })
      return list
    }
    onAgentChoicesChanged: if (agent === "" && agentChoices.length > 0) agent = agentChoices.indexOf("claude") >= 0 ? "claude" : agentChoices[0]

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(8)
      PageHeader { title: root.t("new.title") }

      Flickable {
        Layout.fillWidth: true
        Layout.fillHeight: true
        contentHeight: formCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
        ColumnLayout {
          id: formCol
          width: parent.width
          spacing: Style.space(8)

          Label { text: root.t("new.host"); color: root.dim; font.pixelSize: Style.font.caption }
          Picker {
            Layout.fillWidth: true
            options: pohunek.hosts.filter(function(h) { return h.reachable })
              .map(function(h) { return { value: h.target, label: h.label } })
            value: form.host
            placeholder: root.t("new.host")
            onPicked: function(value) { form.host = value; form.agent = ""; form.project = ""; pohunek.loadForm(value) }
          }

          Label { text: root.t("new.project"); color: root.dim; font.pixelSize: Style.font.caption }
          Picker {
            Layout.fillWidth: true
            options: pohunek.form.projects.map(function(p) { return { value: p.label, label: p.label } })
            value: form.project
            emptyLabel: root.t("new.noProject")
            placeholder: root.t("new.noProject")
            onPicked: function(value) { form.project = value }
          }
          Label {
            visible: pohunek.form.loading || pohunek.form.error !== ""
            text: pohunek.form.loading ? root.t("new.loading") : pohunek.form.error
            color: root.dim
            font.pixelSize: Style.font.caption
          }

          Label { text: root.t("new.agent"); color: root.dim; font.pixelSize: Style.font.caption }
          Picker {
            Layout.fillWidth: true
            options: form.agentChoices.map(function(a) { return { value: a, label: a } })
            value: form.agent
            placeholder: root.t("new.agent")
            onPicked: function(value) { form.agent = value }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            TextField {
              id: nameField
              Keys.onEscapePressed: root.back()
              Layout.fillWidth: true
              placeholderText: root.t("new.name")
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
            TextField {
              id: branchField
              Keys.onEscapePressed: root.back()
              Layout.fillWidth: true
              placeholderText: root.t("new.branch")
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Label { text: root.t("new.prompt"); color: root.dim; font.pixelSize: Style.font.caption }
          QQC.ScrollView {
            Layout.fillWidth: true
            Layout.preferredHeight: Style.space(120)
            QQC.TextArea {
              id: promptField
              wrapMode: TextEdit.Wrap
              textFormat: TextEdit.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              placeholderText: root.t("new.promptPlaceholder")
              placeholderTextColor: root.dim
              background: Rectangle { color: "transparent"; border.width: 1; border.color: root.hairline; radius: Style.cornerRadius }
              Keys.onPressed: function(event) {
                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && (event.modifiers & Qt.ControlModifier)) {
                  form.submit(); event.accepted = true
                } else if (event.key === Qt.Key_Escape) { root.back(); event.accepted = true }
              }
            }
          }
          Label {
            visible: form.group !== "" && form.group.toLowerCase() !== "inbox"
            text: root.t("new.inGroup").arg(form.group)
            color: root.dim
            font.pixelSize: Style.font.caption
          }
        }
      }

      RowLayout {
        Layout.fillWidth: true
        Label { Layout.fillWidth: true; text: root.t("new.hint"); color: root.dim; font.pixelSize: Style.font.caption }
        Button {
          text: root.t("new.start")
          bordered: true
          enabled: form.agent !== "" && !pohunek.form.loading
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: form.submit()
        }
      }
    }
  }
}
