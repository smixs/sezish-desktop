# dmgbuild settings for the sezish distribution DMG.
# Invoked from scripts/make-dmg.sh:
#   uvx dmgbuild -s dmg-settings.py -D app=<sezish.app> -D background=<bg.tiff> sezish <out.dmg>
# dmgbuild writes .DS_Store itself (ds_store + mac_alias) — layout is deterministic,
# unlike Finder/AppleScript which saves .DS_Store asynchronously and loses it.

app = defines["app"]  # noqa: F821 — injected by dmgbuild

format = "UDZO"
filesystem = "HFS+"  # APFS images don't mount on macOS < 10.13

files = [(app, "sezish.app")]
symlinks = {"Applications": "/Applications"}
badge_icon = app + "/Contents/Resources/sezish.icns"

background = defines["background"]  # noqa: F821
default_view = "icon-view"
# Background is 560x400 pt; +28 on height for the title bar.
window_rect = ((200, 180), (560, 428))
icon_size = 110
text_size = 13
scroll_position = (0, 0)
icon_locations = {
    "sezish.app": (150, 205),
    "Applications": (410, 205),
    # Housekeeping files parked off-window: invisible flag hides them from normal
    # users, this keeps the window clean for "show hidden files" users too.
    ".background.tiff": (900, 130),
    ".VolumeIcon.icns": (900, 280),
    ".DS_Store": (900, 430),
}
