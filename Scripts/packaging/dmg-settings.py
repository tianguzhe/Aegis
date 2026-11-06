"""dmgbuild settings for the Aegis installer window, written without Finder or AppleScript.

Icon positions match the halos drawn by GenerateDMGArtwork.swift.
"""

import os
import subprocess

app = os.path.abspath(defines["app"])  # noqa: F821 - provided by dmgbuild
app_filename = os.path.basename(app)
if app_filename != "Aegis.app":
    raise ValueError("The application bundle must be named Aegis.app")

files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
default_view = "icon-view"
window_rect = ((180, 140), (680, 520))
icon_locations = {app_filename: (180, 250), "Applications": (500, 250)}
icon_size = 104
text_size = 13
label_pos = "bottom"
arrange_by = None

# Changing the app bundle's FinderInfo after signing would invalidate its resource seal.
hide_extensions = []
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_item_info = False
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False


def create_hook(mount_point, options):
    """Reject a damaged app copy before the writable image is converted to UDZO."""
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", os.path.join(mount_point, app_filename)],
                   check=True)
