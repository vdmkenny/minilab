#!/usr/bin/env bash
# usage: check-files.sh [--staged]
#
# Fails when a file that must stay out of the repository is in it or about to enter it: the files
# git tracks, or with --staged those the next commit holds, as the pre-commit hook checks them.
# That is a scan, a camera file or a picture (people's own film), a maker's datasheet, a program or
# firmware, or a file over 2 MiB; anything holding binary data, since the repository holds none;
# and a line of text with an em or en dash (U+2014, U+2013), which the project's text does without
# (CONTRIBUTING.md), in any text file but a licence.
set -euo pipefail
export LC_ALL=C

mode=${1:-}
case $mode in
    "" | --staged) ;;
    *) echo "usage: $0 [--staged]" >&2; exit 2 ;;
esac
cd "$(git rev-parse --show-toplevel)"

kept_out='ppm|pgm|pnm|tif|tiff|jpg|jpeg|png|heic|dng|nef|cr2|cr3|arw|raf|orf|rw2|pef|srw|pdf|bin|exe|dll|so|dylib|zip'
max_size=$((2 * 1024 * 1024))
licences='(^|/)LICENSE[^/]*$'
em_dash=$(printf '\342\200\224')
en_dash=$(printf '\342\200\223')

failed=0
fail() {
    printf '  %s: %s\n' "$1" "$2" >&2
    failed=1
}

# Names as they are, not quoted: git puts a name with an accent in quotes, with the accent as
# octal escapes, and the -f check below would then skip it.
paths() {
    case $mode in
        "") git -c core.quotePath=false ls-files ;;
        --staged) git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR ;;
    esac
}

while IFS= read -r path; do
    [ -f "$path" ] || continue
    lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$lower" | grep -Eq "\.($kept_out)$"; then
        fail "$path" "is a kind of file that stays out of the repository"
        continue
    fi
    size=$(wc -c < "$path")
    if [ "$size" -gt "$max_size" ]; then
        fail "$path" "is over 2 MiB"
        continue
    fi
    if grep -Iq . "$path" 2>/dev/null || [ ! -s "$path" ]; then
        # A text file: no dashes, but in a licence.
        if ! printf '%s' "$path" | grep -Eq "$licences"; then
            if grep -n -e "$em_dash" -e "$en_dash" "$path" >/dev/null; then
                fail "$path" "has an em or en dash on line $(grep -n -e "$em_dash" -e "$en_dash" "$path" | head -1 | cut -d: -f1)"
            fi
        fi
    else
        fail "$path" "holds binary data"
    fi
done < <(paths)

if [ "$failed" -ne 0 ]; then
    echo "check-files: the files above can't be committed" >&2
    exit 1
fi
