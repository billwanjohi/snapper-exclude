#!/usr/bin/env bash
## Exclude things like cache from past and future btrfs snapshots
## Caveats:
##   - the resultant directory cannot be removed without a (sudo) btrfs subvolume delete command
##     - `sudo btrfs subvolume delete $TARGET_PATH`
##   - script does not yet manage attributes like CoW (see lsattr and chattr)

set -e  # exit on error
set -u  # fail on unset variables; not a great error message

# Converts relative to absolute paths
TARGET=$(readlink -f "$1")

# This will fail if directory not in a btrfs filesystem
CHILD_SUBVOLS=$(sudo btrfs subvolume list -o "$TARGET")

CURRENT_SUBVOL=$(echo "$CHILD_SUBVOLS" |
                     awk '/\.snapshots$/ {print $NF}' |
                     sed 's/\/[^/]*$//')

if [[ -z "$CURRENT_SUBVOL" ]]; then
    echo "FAIL: the directory's subvolume doesn't have snapshots"
    exit 1
fi

# xargs is used here just to trim whitespace
CURRENT_SUBVOL_MOUNT=$(snapper list-configs |
                           awk -F \| "\$1 ~ /${CURRENT_SUBVOL//@}/ {print \$2}" |
                           xargs)

if [[ -z "$CURRENT_SUBVOL_MOUNT" ]]; then
    echo "FAIL: unable to determine the subvolume mountpoint"
    exit 1
fi

REMOVAL_TARGET=${TARGET/${CURRENT_SUBVOL_MOUNT}\/}

if [[ -z "$CURRENT_SUBVOL_MOUNT" ]]; then
    echo "FAIL: unable to determine the subvolume mountpoint"
    exit 1
fi

echo "The current btrfs subvolume for \"$TARGET\""
echo "is \"$CURRENT_SUBVOL\", mounted at \"$CURRENT_SUBVOL_MOUNT\"."
echo "We're going to pass \"$REMOVAL_TARGET\" to \`xargs rm\`"

echo "File attributes you need to manually set with \`chattr\`:"
lsattr -d "$TARGET"

# We have to collocate $TMP so that it is assigned to the proper parent volume
TMP="${TARGET}_temp_btrfs_subvol"

read -p "Ready to proceed? " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # This must happen immediately before changes begin!
    LOCKS=$(sudo lsof -wa +D "$TARGET" 2>&1 | head -n5)
    if [[ ! -z "$LOCKS" ]]; then
        echo "FAIL: file lock(s) present:"
        echo "$LOCKS"
    exit 1
    fi

    echo "Creating the subvolume with same ownership/permissions..."
    sudo btrfs subvolume create "$TMP"  # will fail if name already taken (good)
    sudo chown --reference="$TARGET" "$TMP"
    sudo chmod --reference="$TARGET" "$TMP"

    echo "Moving the data from directory to subvolume..."
    # move the full contents $TARGET to $TMP (including hidden files)
    sudo find "$TARGET" -mindepth 1 -maxdepth 1 -exec mv -t "$TMP" -- {} +

    sudo rmdir "$TARGET"
    sudo mv "$TMP" "$TARGET"
    echo "Successfully replaced directory with subvolume."

    read -p "Prune snapshots? " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Pruning directory from snapshots..."
        ## TODO: split this into an interactive that can find and remove snapshots of now-moved data
        sudo find "$CURRENT_SUBVOL_MOUNT"/.snapshots -maxdepth 2 -path '*/snapshot' |
            sudo xargs -tI{} btrfs property set -t subvol {} ro false

        # FIXME: only throw away "No such file or directory" errors
        sudo find "$CURRENT_SUBVOL_MOUNT"/.snapshots -maxdepth 2 -path '*/snapshot' |
            sudo xargs -tI{} rm -r {}/"$REMOVAL_TARGET"; true

        # TODO: make this run every time
        sudo find "$CURRENT_SUBVOL_MOUNT"/.snapshots -maxdepth 2 -path '*/snapshot' |
            sudo xargs -tI{} btrfs property set -t subvol {} ro true
    fi

else
    echo "No changes made."
fi

echo "Find some other candidates:"
echo "\`du -mx ~ | grep -i cache | sort -rn | head\`"
