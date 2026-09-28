#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v gum >/dev/null || {
    echo "Error: gum is not installed."
    exit 1
}

command -v makepkg >/dev/null || {
    echo "Error: makepkg is not installed."
    exit 1
}

mapfile -t PACKAGES < <(
    find "$REPO_DIR" \
        -mindepth 2 \
        -maxdepth 2 \
        -name PKGBUILD \
        -printf '%h\n' |
        sort |
        xargs -r -n1 basename
)

if (( ${#PACKAGES[@]} == 0 )); then
    gum style --foreground 1 "No packages with a PKGBUILD found."
    exit 1
fi

ACTION="$(
    gum choose \
        "Install / Update" \
        "Uninstall" \
        "Update AUR"
)"

case "$ACTION" in
    "Install / Update")
        mapfile -t SELECTED < <(
            gum choose \
                --no-limit \
                --header "Select packages to install/update:" \
                "${PACKAGES[@]}"
        )

        if (( ${#SELECTED[@]} == 0 )); then
            exit 0
        fi

        for package in "${SELECTED[@]}"; do
            PACKAGE_DIR="$REPO_DIR/$package"

            gum style \
                --border rounded \
                --padding "0 1" \
                "$package"

            (
                cd "$PACKAGE_DIR"

                gum spin \
                    --spinner dot \
                    --title "Building $package..." \
                    -- \
                    makepkg -Cfs --noconfirm
            )

            PACKAGE_FILE="$(
                find "$PACKAGE_DIR" \
                    -maxdepth 1 \
                    -type f \
                    -name '*.pkg.tar.*' \
                    -printf '%T@ %p\n' |
                    sort -n |
                    tail -n1 |
                    cut -d' ' -f2-
            )"

            if [[ -z "$PACKAGE_FILE" ]]; then
                gum style \
                    --foreground 1 \
                    "Failed to find built package: $package"
                exit 1
            fi

            sudo pacman -U "$PACKAGE_FILE"
        done
        ;;

    "Uninstall")
        INSTALLED=()

        for package in "${PACKAGES[@]}"; do
            if pacman -Qq "$package" &>/dev/null; then
                INSTALLED+=("$package")
            fi
        done

        if (( ${#INSTALLED[@]} == 0 )); then
            gum style \
                --foreground 3 \
                "None of the repository packages are currently installed."
            exit 0
        fi

        mapfile -t SELECTED < <(
            gum choose \
                --no-limit \
                --header "Select packages to uninstall:" \
                "${INSTALLED[@]}"
        )

        if (( ${#SELECTED[@]} == 0 )); then
            exit 0
        fi

        gum confirm \
            "Uninstall ${#SELECTED[@]} package(s)?" ||
            exit 0

        sudo pacman -R "${SELECTED[@]}"
        ;;

    "Update AUR")
        mapfile -t SELECTED < <(
            gum choose \
                --no-limit \
                --header "Select packages to update on AUR:" \
                "${PACKAGES[@]}"
        )

        if (( ${#SELECTED[@]} == 0 )); then
            exit 0
        fi

        AUR_TMPDIR="$(mktemp -d)"

        cleanup() {
            rm -rf "$AUR_TMPDIR"
        }

        trap cleanup EXIT

        for package in "${SELECTED[@]}"; do
            PACKAGE_DIR="$REPO_DIR/$package"
            AUR_DIR="$AUR_TMPDIR/$package"
            AUR_URL="ssh://aur@aur.archlinux.org/$package.git"

            gum style \
                --border rounded \
                --padding "0 1" \
                "$package"

            if git ls-remote "$AUR_URL" &>/dev/null; then
                gum spin \
                    --spinner dot \
                    --title "Cloning AUR repository..." \
                    -- \
                    git clone "$AUR_URL" "$AUR_DIR"
            else
                mkdir -p "$AUR_DIR"

                (
                    cd "$AUR_DIR"
                    git init
                    git branch -M master
                    git remote add origin "$AUR_URL"
                )
            fi

            find "$AUR_DIR" \
                -mindepth 1 \
                -maxdepth 1 \
                ! -name .git \
                -exec rm -rf {} +

            cp -a "$PACKAGE_DIR"/. "$AUR_DIR"/

            (
                cd "$AUR_DIR"

                makepkg --printsrcinfo > .SRCINFO

                git add -A

                if git diff --cached --quiet; then
                    gum style \
                        --foreground 3 \
                        "No changes to push."
                    exit 0
                fi

                git commit -m "Update $package"

                gum spin \
                    --spinner dot \
                    --title "Pushing $package to AUR..." \
                    -- \
                    git push -u origin master
            )
        done
        ;;
esac
