#!/bin/sh

set -e

name=<<<NAME>>>
version=<<<MIN_OS_VERSION>>>

f="$1/$name"

plist_path="$f/Info.plist"
# MARK: Zenlygram — only ever RAISE the bundle's MinimumOSVersion. This patch exists for an app whose floor is lower
# than the extension's own API floor (WidgetKit: 14.0). With --deviceMinimumOS=15.0 the extension's binary is built
# for 15.0, and writing 14.0 back makes App Store validation refuse the IPA (ERROR 90208: the bundle "does not
# support the minimum OS Version specified in the Info.plist"). build-system/appstore/ipa_check.py checks the result.
current=$(plutil -extract MinimumOSVersion raw -o - "$plist_path" 2>/dev/null || true)
highest=$(printf '%s\n%s\n' "$current" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
if [ -z "$current" ] || [ "$highest" != "$current" ]; then
	plutil -replace MinimumOSVersion -string $version "$plist_path"
fi
if [ "$version" == "14.0" ]; then
	binary_path="$f/$(basename $f | sed -e s/\.appex//g)"
	xcrun lipo "$binary_path" -remove armv7 -o "$binary_path" 2>/dev/null || true
fi

# MARK: Swiftgram
find "$1" -type f \( -perm +111 -o -name "*.dylib" \) | while read -r bin; do
  if otool -L "$bin" | grep -q "/usr/lib/swift/libswift_Concurrency.dylib"; then
    echo "Patching concurrency backport in: $bin"
    chmod +w "$(dirname $bin)/"
    install_name_tool -change /usr/lib/swift/libswift_Concurrency.dylib @rpath/libswift_Concurrency.dylib "$bin"
  fi
done