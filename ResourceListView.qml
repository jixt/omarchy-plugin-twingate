import QtQuick
import qs.Ui
import qs.Commons

import "Parsing.js" as Parsing

// Search box + full scrollable list of resource rows — the shared chrome
// reused by all three tabs (Main/Kubernetes/Hidden). The tabs differ only
// in which array and row delegate they pass in.
Column {
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

  TextField {
    id: searchField
    width: parent.width
    foreground: root.foreground
    placeholderText: root.placeholderText
    text: root.query
    onTextChanged: root.query = text
  }

  Text {
    textFormat: Text.PlainText
    visible: root.filteredItems.length === 0
    width: parent.width
    text: root.emptyText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Column {
    width: parent.width
    spacing: Style.space(4)

    Repeater {
      model: root.filteredItems
      delegate: root.delegateComponent
    }
  }
}
