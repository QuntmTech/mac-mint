# dmgbuild settings for MacMint's installer window (scripts/build_dmg.sh passes the -D values).
# Icon positions are icon centers in a 660 x 440 window; Resources/Installer/background*.png
# draws the title, the arrow between the two icons and the footer. Its colors keep Finder's
# black (light) and white (dark) labels at about 4.4:1 contrast or better.
import os.path

app = defines["app"]  # noqa: F821 - provided by dmgbuild
readme = defines["readme"]  # noqa: F821
background = defines["background"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app, readme]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
if not os.path.isfile(icon):
    icon = None

window_rect = ((200, 140), (660, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
icon_size = 96
text_size = 13
arrange_by = None
icon_locations = {
    "MacMint.app": (170, 200),
    "Applications": (490, 200),
    "Install MacMint.txt": (330, 336),
}
# Only the note: hiding an extension writes com.apple.FinderInfo onto the item, and
# `codesign --verify --strict` rejects that on an app bundle. Finder already shows apps
# without ".app" unless the person turned on all filename extensions.
hide_extensions = ["Install MacMint.txt"]
