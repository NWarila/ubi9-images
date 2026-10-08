#!/usr/bin/env bash
#
# remove-install-only.sh - remove the packages that were needed only to build
#                          the image.
#
# Used by stage 2 of every Dockerfile, inside the builder image, after the
# RPMs have been installed into /rootfs.
#   reads    /lock/packages.lock.<architecture>
#   changes  /rootfs
#   checks   every lock line's shape and role, that no package is listed
#            twice, and that rpm succeeds (rpm stops on a package that is not
#            installed, but only warns about a file it cannot delete)
#
# Installing an RPM needs helpers (a shell for its install scripts, the crypto
# policy tool, and so on). The lock marks those packages "install". Once the
# image's files are in place they are removed, so the finished image holds
# only the packages marked "ship".

fail() {
  echo "remove-install-only: $*" >&2
  exit 1
}

machine_arch=$(uname -m) || fail 'cannot read the architecture of this machine'
lock_file=/lock/packages.lock.$machine_arch

[[ -f $lock_file ]] || fail "$lock_file does not exist"

# Read every line, so a misspelt role cannot look like "nothing to remove".
# A line is "package|checksum|address|role", or a comment starting with "#".
install_only=()
declare -A seen_packages=()
line_number=0

# "|| [[ -n $line ]]" keeps a last line that has no newline after it.
while IFS= read -r line || [[ -n $line ]]; do
  ((line_number++))
  [[ $line == '#'* ]] && continue
  where="$lock_file line $line_number"

  # Exactly four fields, none empty, and nothing else on the line.
  [[ $line =~ ^[^|]+\|[^|]+\|[^|]+\|[^|]+$ ]] \
    || fail "$where must have exactly four fields:" \
            'package|checksum|address|role'
  IFS='|' read -r package _ _ role <<< "$line"

  # A package may appear once: never both kept and removed, never counted twice.
  [[ -z ${seen_packages[$package]} ]] \
    || fail "$where repeats package '$package'" \
            "(first used on line ${seen_packages[$package]})"
  seen_packages[$package]=$line_number

  case $role in
    ship) ;;
    install) install_only+=("$package") ;;
    *) fail "$where has role '$role' (expected ship or install)" ;;
  esac
done < "$lock_file"

(( ${#seen_packages[@]} > 0 )) || fail "$lock_file lists no packages"

if (( ${#install_only[@]} == 0 )); then
  echo 'Nothing to remove: every installed package ships in this image.'
  exit 0
fi

# --nodeps      remove them although shipped packages name them as
#               dependencies; leaving those out is the point of a minimal image
# --noscripts   run no package scripts: neither the removed packages' own
# --notriggers  uninstall scripts nor those that packages staying in the image
#               run when another package goes. Most need the shell or tools
#               being removed. The Dockerfiles redo two of them by hand:
#               ldconfig and, where p11-kit-trust is removed, deleting the
#               libnssckbi.so links. rpm's code makes --noscripts imply
#               --notriggers and its manual does not, so both are given.
# --            everything after it is a package name, never an option
rpm --root=/rootfs --erase --nodeps --noscripts --notriggers \
  -- "${install_only[@]}" \
  || fail 'rpm could not remove the install-only packages'

echo "Removed ${#install_only[@]} install-only packages."
