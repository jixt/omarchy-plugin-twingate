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

  function resetQuery() {
    root.query = ""
    searchField.text = ""
  }

  spacing: Style.space(10)

  Row {
    Layout.fillWidth: true
    spacing: Style.space(6)

    TextField {
      id: searchField
      width: parent.width - (root.query !== "" ? clearSearchButton.width + parent.spacing : 0)
      foreground: root.foreground
      placeholderText: root.placeholderText
      text: root.query
      onTextChanged: root.query = text
    }

    PanelActionButton {
      id: clearSearchButton
      visible: root.query !== ""
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
