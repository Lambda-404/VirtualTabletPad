# macOS Application Compatibility Matrix

| Application | Tested Version | Pressure | Tilt | Hover | Notes |
| :--- | :--- | :---: | :---: | :---: | :--- |
| **Krita** | 5.2.x | ⏳ | ⏳ | ⏳ | Verify Tablet Input settings (Wintab vs macOS Native). |
| **Adobe Photoshop** | 2024 / 2025 | ⏳ | ⏳ | ⏳ | Check Brush Dynamics (Pressure / Tilt jitter). |
| **Affinity Photo / Designer** | 2.5.x | ⏳ | ⏳ | ⏳ | Verify Controller setting in Brush panel. |
| **Clip Studio Paint** | 3.0.x | ⏳ | ⏳ | ⏳ | Verify Preferences > Tablet > Processing priority. |
| **Blender (Sculpt / Grease Pencil)** | 4.2+ | ⏳ | ⏳ | ⏳ | Verify Sculpt stroke strength and Grease Pencil pressure. |
| **Pixelmator Pro** | 3.6+ | ⏳ | ⏳ | ⏳ | Native AppKit pointer / pressure integration. |
| **Autodesk SketchBook** | 6.x | ⏳ | ⏳ | ⏳ | Check Puck and Brush properties. |
| **GIMP** | 2.10.x | ⏳ | ⏳ | ⏳ | Configure Extended Input Devices in Preferences. |
| **Inkscape** | 1.3+ | ⏳ | ⏳ | ⏳ | Check Calligraphy tool pressure sensitivity. |
| **Apple Freeform / Notes** | macOS 14+ | ⏳ | ⏳ | ⏳ | Uses system AppKit / PencilKit direct events. |

## Legend

- **✅**: Fully operational
- **⚠️**: Functional with application configuration required
- **❌**: Unsupported or non-functional
- **⏳**: Pending verification
