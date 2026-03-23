#!/bin/bash

# Parse hyprland.conf and list all configured keybindings

config_file="$HOME/.config/hypr/hyprland.conf"

if [[ ! -f "$config_file" ]]; then
    echo "Error: $config_file not found"
    exit 1
fi

echo "Hyprland Keybindings:"
echo "===================="
# Format: bind[flags] = MODS, KEY, DISPATCHER, [PARAMS]
grep -E '^\s*bind\w*\s*=' "$config_file" | while read -r line; do
    bind_def="${line#*=}"

    # Split by comma into fields: mods, key, dispatcher, args...
    IFS=',' read -r mods key dispatcher args <<< "$bind_def"

    # Trim whitespace
    mods="${mods#"${mods%%[![:space:]]*}"}"; mods="${mods%"${mods##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    dispatcher="${dispatcher#"${dispatcher%%[![:space:]]*}"}"; dispatcher="${dispatcher%"${dispatcher##*[![:space:]]}"}"
    args="${args#"${args%%[![:space:]]*}"}"; args="${args%"${args##*[![:space:]]}"}"
    # Strip inline comments from args
    args="${args%%#*}"
    args="${args%"${args##*[![:space:]]}"}"

    [[ -z "$dispatcher" ]] && continue

    # Build key combo: "MODS KEY"
    if [[ -n "$mods" ]]; then
        key_combo="$mods $key"
    else
        key_combo="$key"
    fi

    echo "${dispatcher}|${args}|${key_combo}"
done | sort -t'|' -k1,1 -k2,2 | awk -F'|' '
    NR==1 { group=$1; print "\n[" group "]"; printf "  %-40s %s\n", $2, $3; next }
    $1!=group { group=$1; print "\n[" group "]" }
    { printf "  %-40s %s\n", $2, $3 }
'
