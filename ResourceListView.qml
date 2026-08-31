import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Ui
import qs.Commons

import "Parsing.js" as Parsing

// Search box (fixed) + a scrollable list of resource rows — the shared
// chrome reused by whichever tab is active (Main/Kubernetes/Hidden). Only
// the row list itself scrolls, inside its own Flickable; the search box
// and "no matching" text stay put above it, same as the panel's header and
// footer stay put around this whole component.
ColumnLayout {
  id: root
  property var panelRoot: null
  property var items: []
  property Component delegateComponent: null
  property string placeholderText: "Search…"
  property string emptyText: "No matching items."
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.55)
  property string fontFamily: Style.font.family

  property string query: ""
  readonly property var filteredItems: Parsing.filterResourceRows(items, query)

  // So the panel's PanelKeyCatcher (Escape-to-close) can block itself while
  // the user is typing here — otherwise it would intercept every keystroke
  // (including plain letters) before they ever reach this field.
  readonly property alias searchFieldFocused: searchField.activeFocus

  function resetQuery() {
    root.query = ""
    searchField.text = ""
  }

  // Gives the search field keyboard focus — used by Panel.qml's `s` shortcut.
  // Once focused, `searchFieldFocused` (bound to PanelKeyCatcher's `blocked`)
  // goes true on its own, so subsequent keystrokes land in the field instead
  // of being intercepted as more shortcuts.
  function focusSearch() {
    searchField.forceActiveFocus()
  }

  // Scrolls the row at `index` into view within this component's own
  // Flickable — kept self-contained (callers never touch rowsFlickable/
  // rowsColumn directly) so the keyboard cursor in Panel.qml can drive it
  // without knowing this view's internals.
  function scrollIndexIntoView(index) {
    if (index < 0 || index >= rowsColumn.children.length) return
    Qt.callLater(function() {
      var item = rowsColumn.children[index]
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(rowsFlickable.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = rowsFlickable.contentY
      var viewBottom = viewTop + rowsFlickable.height
      var maxY = Math.max(0, rowsFlickable.contentHeight - rowsFlickable.height)
      if (top < viewTop + margin) rowsFlickable.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) rowsFlickable.contentY = Math.min(maxY, bottom + margin - rowsFlickable.height)
    })
  }

  spacing: Style.space(10)

  TextField {
    id: searchField
    Layout.fillWidth: true
    rightPadding: horizontalPadding + (root.query !== "" ? clearSearchButton.width + Style.space(2) : 0)
    foreground: root.foreground
    placeholderText: root.placeholderText
    text: root.query
    onTextChanged: root.query = text

    // Down: jump straight into the list, matching the same key's meaning
    // once focus is already there (move to the next row). Escape is
    // staged — clear the query first, and only hand focus back to the
    // main panel view on a second press once there's nothing left to
    // clear, so it never skips past "start over."
    Keys.onDownPressed: function(event) {
      event.accepted = true
      if (root.panelRoot && typeof root.panelRoot.jumpToFirstListItem === "function") root.panelRoot.jumpToFirstListItem()
    }
    Keys.onEscapePressed: function(event) {
      event.accepted = true
      if (root.query !== "") root.resetQuery()
      else if (root.panelRoot && typeof root.panelRoot.focusMainPanel === "function") root.panelRoot.focusMainPanel()
    }

    PanelActionButton {
      id: clearSearchButton
      visible: root.query !== ""
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      size: Style.space(20)
      iconText: "\u{F0156}"
      tooltipText: "Clear search"
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: searchField.text = ""
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: root.filteredItems.length === 0
    Layout.fillWidth: true
    text: root.emptyText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Flickable {
    id: rowsFlickable
    Layout.fillWidth: true
    Layout.fillHeight: true
    implicitHeight: rowsColumn.implicitHeight
    contentWidth: width
    contentHeight: rowsColumn.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.VerticalFlick
    interactive: contentHeight > height
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    Column {
      id: rowsColumn
      width: rowsFlickable.width
      spacing: Style.space(4)

      Repeater {
        model: root.filteredItems
        delegate: root.delegateComponent
      }
    }
  }
}
