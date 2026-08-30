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

  Item {
    id: rowsViewport
    Layout.fillWidth: true
    Layout.fillHeight: true
    // The outer panel's own contentHeight is computed manually from
    // implicitHeight all the way up (Panel.qml has no ancestor Flickable
    // sizing it), so this wrapper — now the actual Layout child instead of
    // the Flickable itself — has to keep propagating it, or that formula
    // silently collapses this whole list to zero height.
    implicitHeight: rowsColumn.implicitHeight

    Flickable {
      id: rowsFlickable
      anchors.fill: parent
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

    // Scroll scrims — same "opacity tracks hidden distance, not a timed
    // fade" technique as omarchy.menu's own results list, but darkening
    // toward black rather than fading to Color.popups.background: that
    // background is fully opaque and nearly identical to the rows' own
    // background, so a same-color fade only visibly affects non-background
    // pixels (icons/text) and turned out imperceptible in practice — a
    // black vignette darkens whatever's underneath regardless of its color.
    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: Math.min(Style.space(20), parent.height / 2)
      visible: opacity > 0
      opacity: rowsFlickable.contentHeight > rowsFlickable.height
        ? Math.max(0, Math.min(1, (rowsFlickable.contentY - rowsFlickable.originY) / height))
        : 0
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.55) }
        GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0) }
      }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      height: Math.min(Style.space(20), parent.height / 2)
      visible: opacity > 0
      opacity: rowsFlickable.contentHeight > rowsFlickable.height
        ? Math.max(0, Math.min(1, (rowsFlickable.originY + rowsFlickable.contentHeight - rowsFlickable.height - rowsFlickable.contentY) / height))
        : 0
      gradient: Gradient {
        GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0) }
        GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.55) }
      }
    }
  }
}
