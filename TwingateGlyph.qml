import QtQuick
import QtQuick.Shapes
import qs.Commons

// Vector redraw of the Twingate mark (traced from icon.svg), rendered as
// real paths instead of a raster/effect combo so it stays crisp at any
// size and recolors instantly with the theme, matching the other bar icons.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  implicitWidth: iconSize
  implicitHeight: iconSize

  Shape {
    id: glyph
    width: 195
    height: 325
    anchors.centerIn: parent
    // 0.85x leaves a small margin around the glyph instead of touching the
    // canvas edge-to-edge, matching how the other bar icons breathe.
    scale: Math.min(root.iconSize / width, root.iconSize / height) * 0.85
    antialiasing: true
    // The curve renderer does analytic, resolution-independent antialiasing
    // that stays sharp under heavy downscaling (this shape is drawn at 195x325
    // and squeezed down to ~iconSize px); the default renderer tessellates
    // once at the declared size and blurs badly once `scale` shrinks it this
    // much. No layer/effect needed either — this draws straight to the
    // framebuffer at final resolution instead of rasterizing to a texture first.
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      PathSvg { path: "M99.000,22.600 c-16.800,12.400 -39.700,29.400 -51.000,37.700 c-25.700,19.000 -35.200,28.300 -40.900,39.800 c-7.200,14.600 -7.200,14.200 -6.900,101.600 l0.300,77.100 l23.500,-16.200 l23.500,-16.200 l0.600,-47.000 c0.600,-51.900 0.600,-52.100 7.500,-66.200 c6.200,-12.800 17.000,-22.100 68.700,-59.700 l6.700,-4.900 l0.000,-34.300 c0.000,-18.900 -0.300,-34.300 -0.700,-34.200 c-0.500,-0.000 -14.500,10.200 -31.300,22.500 z" }
    }

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      PathSvg { path: "M157.500,72.600 c-62.900,46.400 -65.800,48.700 -74.200,57.000 c-6.300,6.400 -9.100,10.100 -12.300,16.600 c-7.000,14.200 -7.100,14.700 -6.800,101.900 l0.300,76.700 l16.000,-11.000 c86.500,-59.600 99.600,-70.200 107.900,-86.900 c6.500,-13.100 6.500,-14.100 6.600,-102.200 c0.000,-43.300 -0.300,-78.700 -0.700,-78.700 c-0.500,0.100 -17.000,12.000 -36.800,26.600 z" }
    }
  }
}
