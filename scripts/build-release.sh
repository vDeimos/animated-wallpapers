#!/bin/bash
set -euo pipefail

if [[ $# != 2 ]]; then
    printf 'Usage: %s /path/to/Gifpapers /path/to/output-directory\n' "$0" >&2
    exit 64
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
library="$(cd "$1" && pwd)"
/bin/mkdir -p "$2"
output="$(cd "$2" && pwd)"
package="$output/Animated Wallpapers.pkg"
if [[ -e "$package" ]]; then
    printf 'An installer already exists in the output directory.\n' >&2
    exit 73
fi
work=$(/usr/bin/mktemp -d "$output/.build.XXXXXX")

payload="$work/payload"
app="$payload/Applications/Animated Wallpapers.app"
support="$payload/Library/Application Support/Animated Wallpapers"
/bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$support/Library" "$payload/Library/LaunchAgents" "$work/scripts"
/bin/cp "$repo/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/bin/ditto "$repo/Resources" "$app/Contents/Resources"
/bin/mv "$app/Contents/Resources/Info.plist" "$app/Contents/Info.plist"
/usr/bin/install -m 0755 "$repo/scripts/postinstall" "$work/scripts/postinstall"

/usr/bin/python3 -B - "$work" "$library" <<'PY'
from pathlib import Path
import plistlib
import shutil
import sys

work=Path(sys.argv[1])
library=Path(sys.argv[2])
payload=work/"payload"
output=payload/"Library/Application Support/Animated Wallpapers/Library"
expected=None
for folder,ext in [("4K Wallpapers",".mp4"),("Desktop Stills",".jpg"),("User Icons",".png")]:
    sources=sorted(p for p in (library/folder).glob("*"+ext) if p.is_file() and not p.is_symlink())
    names={p.stem for p in sources}
    if not names or (expected is not None and names!=expected):
        raise RuntimeError("The video, still and icon filenames must match.")
    expected=names
    (output/folder).mkdir()
    for source in sources:
        shutil.copyfile(source,output/folder/source.name)
print(f"Staged {len(expected)} videos with matching stills and user icons.")

label="local.gifpapers.animated-wallpapers.installed-lock-screen"
agent={
    "Label":label,
    "ProgramArguments":["/Library/Application Support/Animated Wallpapers/LockScreenSync"],
    "LimitLoadToSessionType":"Aqua",
    "RunAtLoad":True,
    "StartInterval":10,
    "ThrottleInterval":2,
    "ProcessType":"Background",
}
(payload/"Library/LaunchAgents"/(label+".plist")).write_bytes(plistlib.dumps(agent))
(work/"requirements.plist").write_bytes(plistlib.dumps({"arch":["arm64"],"os":["26.0"],"home":False}))
PY

/usr/bin/swiftc -O -target arm64-apple-macos26.0 -parse-as-library -module-cache-path "$work/cache" \
    "$repo/Sources/"{DesktopPlayback,AnimatedWallpapers,AccountPicturePanel,ProfilePicture,WallpaperBrowser,AppleAccountSync,FirstLaunchSetup}.swift \
    -o "$app/Contents/MacOS/AnimatedWallpapers"
/usr/bin/swiftc -O -suppress-warnings -target arm64-apple-macos26.0 -parse-as-library -module-cache-path "$work/cache" \
    "$repo/Sources/LockScreenSync.swift" -o "$support/LockScreenSync"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --force --sign - "$support/LockScreenSync"
/usr/bin/codesign --verify --strict "$app"
/usr/bin/codesign --verify --strict "$support/LockScreenSync"

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
/usr/bin/pkgbuild --analyze --root "$payload" "$work/components.plist"
/usr/bin/python3 -B - "$work/components.plist" <<'PY'
from pathlib import Path
import plistlib
import sys
p=Path(sys.argv[1])
components=plistlib.loads(p.read_bytes())
assert len(components)==1 and components[0]["RootRelativeBundlePath"]=="Applications/Animated Wallpapers.app"
components[0]["BundleIsRelocatable"]=False
components[0]["BundleOverwriteAction"]="upgrade"
p.write_bytes(plistlib.dumps(components))
PY
/usr/bin/pkgbuild --root "$payload" --component-plist "$work/components.plist" --scripts "$work/scripts" \
    --identifier local.gifpapers.animated-wallpapers.install --version "$version" --install-location / \
    --ownership recommended --compression latest --min-os-version 26.0 "$work/AnimatedWallpapersPayload.pkg"
/usr/bin/productbuild --synthesize --product "$work/requirements.plist" --package "$work/AnimatedWallpapersPayload.pkg" "$work/Distribution.xml"
/usr/bin/python3 -B - "$work/Distribution.xml" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
p=Path(sys.argv[1])
tree=ET.parse(p)
root=tree.getroot()
title=root.find("title")
if title is None:
    title=ET.Element("title")
    root.insert(0,title)
title.text="Animated Wallpapers"
root.find("options").set("customize","never")
tree.write(p,encoding="utf-8",xml_declaration=True)
PY
/usr/bin/productbuild --distribution "$work/Distribution.xml" --package-path "$work" "$package"
/usr/sbin/installer -pkginfo -pkg "$package" -target /
printf 'Built %s\n' "$package"
