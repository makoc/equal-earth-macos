# Equal Earth Explorer

A native macOS app for exploring the [Equal Earth projection](https://equal-earth.com/equal-earth-projection.html) (Šavrič, Patterson, Jenny, 2018) in **oblique aspects**. You turn the globe *underneath* the map: every point is first rotated in 3D and then projected with the standard Equal Earth formulas, so any place can be in the centre and the map can be cut open anywhere.

## Features

- Full-window Equal Earth map, rendered per pixel on the GPU (Graphics Processing Unit) with Metal, so the imagery is never resampled when you rotate.
- **Grab-and-drag**: the point under the pointer follows the pointer. **Option-drag** or the two-finger trackpad rotation turns the map about its centre (roll). Scrolling also moves the globe.
- Side panel with a globe in the same orientation. The red line shows where the map is cut open (the map-frame antimeridian); the cyan lines are the map's equator and central meridian. You can drag the globe too.
- **North Up** (⌘N) keeps the map centre and removes the roll. **0°, 0°** (⌘0) returns to the standard map. Both are animated.
- Overlays that can be toggled: 15° graticule, coastlines, country borders, Tissot indicatrices (equal-area circles that show how the projection distorts shape), map outline with the original North and South Poles.
- Readouts: map centre, roll angle, the North Pole's position on the map, and the coordinates under the pointer.

## Requirements and build

- macOS 27 and Xcode 27. The app uses only system frameworks: SwiftUI, AppKit, Metal, MetalKit, ImageIO, simd and Foundation.
- Open `EqualEarthExplorer.xcodeproj` and run the *EqualEarthExplorer* scheme. Signing is set to "Sign to Run Locally". Choose your team under *Signing & Capabilities* to distribute the app.
- ⌘U runs the unit tests (Swift Testing): projection round trip and reference values, rotation conventions, and a check that the Metal shader matches the Swift implementation.

## Data

| Data | Source | Size | How it gets in |
|---|---|---|---|
| Earth imagery: NASA Blue Marble Next Generation, topography and bathymetry, December 2004, 21 600 × 10 800 px | [NASA Earth Observatory](https://science.nasa.gov/earth/earth-observatory/blue-marble-next-generation/base-topography-bathymetry/) | 29.9 MB | Downloaded on first launch, **only after you agree** in a window that shows the URL, the size and a progress bar. Cached in the app's Application Support folder. Menu *Globe → Delete Cached Imagery* removes it. |
| Coastlines and land borders, 1:50 million | [Natural Earth](https://www.naturalearthdata.com/) | 2.4 MB | Bundled (`EqualEarthExplorer/Resources`) |

All data is in the public domain. The image is decoded to an 8192 × 4096 px texture with mipmaps (about 180 MB of GPU memory).

## How it works

Unit vectors: x → (0° N, 0° E), y → (0° N, 90° E), z → North Pole. The orientation is a unit quaternion `R` that maps geographic vectors into the *map frame*; the map centre is +x in that frame.

- **Raster (per pixel, `Shaders.metal`)**: pixel → inverse Equal Earth (Newton iteration for θ) → map-frame vector v′ → geographic v = R⁻¹ v′ → latitude/longitude → texture.
- **Lines**: geographic polylines are split once into segments of at most 0.5°. The vertex shader rotates and projects both ends of each segment and drops segments that cross the cut line. Each segment is drawn as an anti-aliased capsule.
- **Dragging**: R ← q(p₀ → p₁) · R₀, where q is the shortest-arc rotation between the map-frame vectors under the pointer at mouse-down and now.
- **North Up**: roll γ = atan2(−n′.y, n′.z) with n′ = R · ẑ (the North Pole in the map frame); then R ← Rₓ(−γ) · R.

Forward projection, with A₁ = 1.340264, A₂ = −0.081106, A₃ = 0.000893, A₄ = 0.003796:

θ = asin(√3/2 · sin φ), x = 2√3 · λ · cos θ / (3 · (9A₄θ⁸ + 7A₃θ⁶ + 3A₂θ² + A₁)), y = A₄θ⁹ + A₃θ⁷ + A₂θ³ + A₁θ

## Project layout

```
EqualEarthExplorer/
  App/         app entry point and menu commands
  Model/       ViewState (orientation, overlay toggles), formatting
  Math/        Equal Earth projection, rotations, view layout
  Geo/         GeoJSON loader, overlay geometry
  Data/        imagery download, cache and decoding
  Rendering/   Metal shaders and renderer
  Views/       SwiftUI views and the interactive Metal view
  Resources/   Natural Earth GeoJSON, asset catalog
EqualEarthExplorerTests/
```
