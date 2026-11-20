# dmgbuild settings for Argent's disk image, read by scripts/build-dmg.sh with -D app=... -D background=...
# The icon positions are the marks drawn by design/dmg/background.py (APP and APPLICATIONS); keep the two in step.
import os.path

app = defines["app"]  # noqa: F821, dmgbuild supplies defines
app_name = os.path.basename(app)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/Argent.icns")

# lzfse, opens on any Mac that runs Argent. HFS+ since the volume is read-only and small.
format = "ULFO"
filesystem = "HFS+"

background = defines["background"]  # noqa: F821; dmgbuild finds background@2x.png beside it
window_rect = ((200, 140), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (160, 196),
    "Applications": (480, 196),
}
