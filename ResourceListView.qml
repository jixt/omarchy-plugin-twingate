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

  spacing: Style.space(10)

  TextField {
    id: searchField
    Layout.fillWidth: true
    rightPadding: horizontalPadding + (root.query !== "" ? clearSearchButton.width + Style.space(2) : 0)
    foreground: root.foreground
    placeholderText: root.placeholderText
    text: root.query
    onTextChanged: root.query = text

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
