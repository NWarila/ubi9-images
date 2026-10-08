#!/usr/bin/env bash
#
# generate-lock.sh - write down exactly which RPM files an image is built from.
#
# WHY THIS EXISTS
#   images/<image>/packages.txt names the packages an image ships. A name is not
#   enough to build the same image twice: Red Hat publishes new versions every
#   week. This script asks the package manager which exact files those names
#   mean today, and records each file's version, checksum and download address
#   in images/<image>/packages.lock.<architecture>.
#
#   The Dockerfile installs the files in the lock and nothing else. The lock
#   only changes when someone runs this script, and the change is an ordinary
#   diff that can be reviewed.
#
# HOW TO RUN IT
#   From the repository root, inside the builder image the Dockerfiles use
#   (the BUILDER line at the top of any Dockerfile), once per architecture:
#
#     builder=$(sed -n 's/^ARG BUILDER=//p' images/micro/Dockerfile)
#
#     podman run --rm --platform linux/amd64 --volume "$PWD":/repo:z \
#         --workdir /repo "$builder" build/generate-lock.sh micro
#
#     podman run --rm --platform linux/arm64 --volume "$PWD":/repo:z \
#         --workdir /repo "$builder" build/generate-lock.sh micro
#
#   ":z" lets a host that runs SELinux share the folder with the container.
#   The run for the other architecture needs that architecture's emulation
#   (qemu-user-static).
#
# WHAT IT READS
#   images/<image>/packages.txt    the packages the image ships
#   images/<image>/modules.txt     optional: module streams to switch on first
#                                  (for example nodejs:24)
#   build/install-tools.txt        packages needed only while an image is built
#   build/held-rpms.<arch>.txt     RPM files kept at a fixed version instead of
#                                  the one Red Hat currently publishes
#
# WHAT IT WRITES
#   images/<image>/packages.lock.<arch>, one line per RPM file:
#
#       package | sha256 checksum | download address | role
#
#   role is "ship"    - the package stays in the finished image, or
#           "install" - the package is needed only while the image is built
#                       and is removed before the image is finished.
#
#   The lock also records one date, "source-date-epoch": the date of the newest
#   file inside those RPM files. The build gives that date to every file it
#   creates itself, so the same lock always produces the same image.
#
# WHAT IT CHECKS
#   Every list file must be readable, and every entry must be a plain package
#   name or module stream; every listed name must be installed under that very
#   name (a misspelt name that some other package happens to provide is
#   refused); every package that ships must be among the packages the build
#   installs; a held RPM must match its recorded checksum, be built for this
#   architecture and be held only once; every package the build installs must
#   have a row; the exact set of locked RPM files must install together into
#   an empty root (rpm --test); and the package manager's own failures stop
#   the run.
#
# WHICH PACKAGES SHIP
#   A folder ending in -toolset is a build environment: it ships the listed
#   packages and everything they depend on.
#   Every other folder ships the listed packages and nothing else.

# The same sort order on every machine, so the lock never reorders itself.
export LC_ALL=C

fail() {
  echo "generate-lock: $*" >&2
  exit 1
}

(( $# == 1 )) \
  || fail 'usage: build/generate-lock.sh <image>   (example: micro)'
image=$1

# An image is a plain folder name under images/: no path, no capitals, and
# not an option such as --help.
[[ $image =~ ^[a-z0-9][a-z0-9-]*$ ]] \
  || fail "image name '$image' must be lower-case letters, digits and" \
          'hyphens, starting with a letter or digit'

arch=$(uname -m) || fail 'cannot read the architecture of this machine'
image_dir=images/$image
lock_file=$image_dir/packages.lock.$arch

[[ -f $image_dir/packages.txt ]] \
  || fail "$image_dir/packages.txt does not exist; run this from the" \
          'repository root, naming a folder under images/'
[[ -f build/install-tools.txt ]] \
  || fail 'build/install-tools.txt does not exist'
[[ -f build/held-rpms.$arch.txt ]] \
  || fail "build/held-rpms.$arch.txt does not exist"

# Working files for this run, removed when the script ends. Everything the
# run creates lives under here, so a second run can never see the first.
notes=$(mktemp --directory) || fail 'cannot create a working directory'
lock_in_progress=''
cleanup() {
  local status=$? cleanup_failed=false
  if ! rm --recursive --force -- "$notes"; then
    echo "generate-lock: cannot remove working directory $notes" >&2
    cleanup_failed=true
  fi
  if [[ -n $lock_in_progress ]] && ! rm --force -- "$lock_in_progress"; then
    echo "generate-lock: cannot remove temporary lock $lock_in_progress" >&2
    cleanup_failed=true
  fi
  if (( status == 0 )) && [[ $cleanup_failed == true ]]; then
    status=1
  fi
  trap - EXIT
  exit "$status"
}
trap cleanup EXIT
# The package manager keeps every RPM it downloads here, so each file can be
# checksummed afterwards.
rpm_cache=$notes/cache
# Two trial installs into empty directories: the listed packages alone, and
# the listed packages plus the install tools. Nothing installed here reaches
# an image; the point is to learn which files the names resolve to.
trial_ship=$notes/ship
trial_all=$notes/all

microdnf_options=(
  --assumeyes
  # An empty trial directory has no release file to read the version from.
  --releasever=9
  # An empty trial directory has no repository settings; use the builder's.
  # microdnf refuses --installroot unless --noplugins, --config, cachedir,
  # reposdir and varsdir are all given.
  --noplugins
  --config=/etc/dnf/dnf.conf
  --setopt=reposdir=/etc/yum.repos.d
  --setopt=varsdir=/etc/dnf/vars
  --setopt=cachedir="$rpm_cache"
  --setopt=keepcache=1
  # Required dependencies only, and no documentation.
  --setopt=install_weak_deps=0
  --nodocs
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print the entries of a list file, one per line: comments and blank lines
# removed, surrounding whitespace trimmed. Fails when the file cannot be read.
read_list() {
  local line trimmed
  while IFS= read -r line || [[ -n $line ]]; do
    # A file saved with Windows line endings is still a list.
    line=${line%$'\r'}
    line=${line%%#*}
    # read with the default IFS trims whitespace from both ends.
    read -r trimmed <<< "$line"
    # An "if", not "&&": a blank last line must not become the status.
    if [[ -n $trimmed ]]; then
      printf '%s\n' "$trimmed"
    fi
  done < "$1"
}

# Print the entries of a list file sorted and without repeats.
read_sorted_list() {
  local entries
  entries=$(read_list "$1") || return 1
  [[ -z $entries ]] || sort --unique <<< "$entries"
}

# Stop unless every argument after the first is a plain package name: the
# characters Fedora allows in one, starting with a letter or digit. Anything
# else would reach the package manager as an option (--nogpgcheck) or a
# pattern before the name check in step 3 could refuse it.
check_package_names() {
  local file=$1 name
  shift
  for name in "$@"; do
    [[ $name =~ ^[[:alnum:]][[:alnum:]._+-]*$ ]] \
      || fail "$file: '$name' is not a package name"
  done
}

# Print the name of every package installed in a trial directory, except the
# signing keys rpm records as packages.
installed_names() {
  local names name
  names=$(rpm --root="$1" --query --all --queryformat '%{NAME}\n') \
    || fail "rpm cannot list the packages installed in $1"
  while IFS= read -r name; do
    [[ $name == gpg-pubkey ]] || printf '%s\n' "$name"
  done <<< "$names"
}

# Print the date of the newest file inside an RPM file, in seconds since 1970
# (0 for a package that carries no files).
newest_file_date() {
  local dates date newest=0
  dates=$(rpm --query --package --nosignature \
    --queryformat '[%{FILEMTIMES}\n]' "$1") \
    || fail "rpm cannot read $1"
  while IFS= read -r date; do
    if [[ -n $date ]] && (( date > newest )); then
      newest=$date
    fi
  done <<< "$dates"
  printf '%s\n' "$newest"
}

# Print where a Red Hat UBI repository publishes its RPM files.
repository_address() {
  local base=https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/$arch
  case $1 in
    ubi-9-baseos-rpms)    printf '%s\n' "$base/baseos/os" ;;
    ubi-9-appstream-rpms) printf '%s\n' "$base/appstream/os" ;;
    *) fail "a package came from repository '$1', which this script does" \
            'not know' ;;
  esac
}

# ---------------------------------------------------------------------------
# Step 1 of 6: read the lists
# ---------------------------------------------------------------------------
echo 'Step 1 of 6: reading the package lists'

# The entries are kept in a variable first because mapfile would read one
# empty line from an empty list.
listed_text=$(read_sorted_list "$image_dir/packages.txt") \
  || fail "cannot read $image_dir/packages.txt"
[[ -n $listed_text ]] || fail "$image_dir/packages.txt lists no packages"
mapfile -t listed <<< "$listed_text"
check_package_names "$image_dir/packages.txt" "${listed[@]}"

tools_text=$(read_sorted_list build/install-tools.txt) \
  || fail 'cannot read build/install-tools.txt'
tools=()
[[ -z $tools_text ]] || mapfile -t tools <<< "$tools_text"
check_package_names build/install-tools.txt "${tools[@]}"

# The held lines are checked now, so a bad one is reported before the long
# download, in the same shape download-rpms.sh will demand of every lock row.
held_list=build/held-rpms.$arch.txt
held_text=$(read_list "$held_list") || fail "cannot read $held_list"
held_lines=()
[[ -z $held_text ]] || mapfile -t held_lines <<< "$held_text"
held_checksums=()
held_addresses=()
for held_line in "${held_lines[@]}"; do
  read -r checksum address extra <<< "$held_line"
  [[ -z $extra && $checksum =~ ^[[:xdigit:]]{64}$ ]] \
    || fail "$held_list: a line must be '<sha256 checksum>  <https" \
            "address>', found: $held_line"
  held_name=${address##*/}
  [[ $address =~ ^https://[^/]+/ && $address != *'?'* && $address != *'#'* \
     && $held_name =~ ^[[:alnum:]][[:alnum:]_.+~^-]*\.rpm$ ]] \
    || fail "$held_list: not a plain https address of an RPM file:" \
            "$address"
  held_checksums+=("$checksum")
  held_addresses+=("$address")
done

# ---------------------------------------------------------------------------
# Step 2 of 6: switch on module streams, if the image uses any
# ---------------------------------------------------------------------------
if [[ -f $image_dir/modules.txt ]]; then
  modules_text=$(read_list "$image_dir/modules.txt") \
    || fail "cannot read $image_dir/modules.txt"
  [[ -n $modules_text ]] \
    || fail "$image_dir/modules.txt lists no module streams"
  mapfile -t modules <<< "$modules_text"
  for module in "${modules[@]}"; do
    [[ $module =~ ^[[:alnum:]][[:alnum:]._+-]*:[[:alnum:]._+-]+$ ]] \
      || fail "$image_dir/modules.txt: '$module' is not a module stream" \
              '(name:stream)'
  done
  echo "Step 2 of 6: switching on module streams: ${modules[*]}"
  for trial in "$trial_ship" "$trial_all"; do
    if ! microdnf "${microdnf_options[@]}" --installroot="$trial" \
        module enable "${modules[@]}" > "$notes/modules.log" 2>&1; then
      tail --lines=20 "$notes/modules.log" >&2
      fail "could not switch on ${modules[*]}"
    fi
  done
else
  echo 'Step 2 of 6: no module streams for this image'
fi

# ---------------------------------------------------------------------------
# Step 3 of 6: let the package manager choose and download the RPM files
# ---------------------------------------------------------------------------
echo "Step 3 of 6: resolving ${#listed[@]} listed packages" \
     '(this downloads the RPM files)'

if ! microdnf "${microdnf_options[@]}" --installroot="$trial_ship" \
    install "${listed[@]}" > "$notes/ship.log" 2>&1; then
  tail --lines=20 "$notes/ship.log" >&2
  fail 'the listed packages could not be installed'
fi

if ! microdnf "${microdnf_options[@]}" --installroot="$trial_all" \
    install "${listed[@]}" "${tools[@]}" > "$notes/all.log" 2>&1; then
  tail --lines=20 "$notes/all.log" >&2
  fail 'the listed packages plus the install tools could not be installed'
fi

# The lists are captured first: a fail inside "< <( ... )" cannot stop the
# script, a fail inside "$( ... ) || exit 1" can.
declare -A installed_ship=()
declare -A installed_all=()
installed=$(installed_names "$trial_ship") || exit 1
while IFS= read -r name; do
  installed_ship[$name]=1
done <<< "$installed"
installed=$(installed_names "$trial_all") || exit 1
while IFS= read -r name; do
  installed_all[$name]=1
done <<< "$installed"

# A misspelt name can be satisfied by a different package. Refuse that, for
# the image's packages and for the install tools alike.
not_installed=()
for name in "${listed[@]}"; do
  [[ -n ${installed_ship[$name]} ]] || not_installed+=("$name")
done
for name in "${tools[@]}"; do
  [[ -n ${installed_all[$name]} ]] || not_installed+=("$name")
done
(( ${#not_installed[@]} == 0 )) \
  || fail 'listed but not installed under that name:' "${not_installed[*]}"

# ---------------------------------------------------------------------------
# Step 4 of 6: decide which packages ship
# ---------------------------------------------------------------------------
declare -A ships=()
case $image in
  *-toolset)
    echo 'Step 4 of 6: a toolset ships the listed packages and everything' \
         'they depend on'
    for name in "${!installed_ship[@]}"; do
      ships[$name]=1
    done
    ;;
  *)
    echo 'Step 4 of 6: this image ships the listed packages and nothing else'
    for name in "${listed[@]}"; do
      ships[$name]=1
    done
    ;;
esac

# Every package that ships must be among the packages the build will install.
not_available=()
for name in "${!ships[@]}"; do
  [[ -n ${installed_all[$name]} ]] || not_available+=("$name")
done
(( ${#not_available[@]} == 0 )) \
  || fail 'would ship but would not be installed during the build:' \
          "${not_available[*]}"

# ---------------------------------------------------------------------------
# Step 5 of 6: record every RPM file the build will install
#
# One row per package name: its full name, checksum, address and the date of
# its newest file.
# ---------------------------------------------------------------------------
echo 'Step 5 of 6: recording each RPM file'

declare -A row_package=()
declare -A row_checksum=()
declare -A row_address=()
declare -A row_newest=()
declare -A row_file=()

# The cache keeps files in <cache>/metadata/<repository>-9-<arch>/packages/.
# nullglob: a pattern that matches nothing expands to nothing, so an empty
# cache gives an empty loop instead of a literal "*.rpm".
shopt -s nullglob
for rpm_file in "$rpm_cache"/metadata/*/packages/*.rpm; do
  name=$(rpm --query --package --nosignature --queryformat '%{NAME}' \
    "$rpm_file") \
    || fail "rpm cannot read $rpm_file"

  # Skip a downloaded file that the build will not install.
  [[ -n ${installed_all[$name]} ]] || continue
  [[ -z ${row_package[$name]} ]] \
    || fail "two RPM files for the package '$name' were downloaded"

  row_package[$name]=$(rpm --query --package --nosignature \
    --queryformat '%{NEVRA}' "$rpm_file") \
    || fail "rpm cannot read $rpm_file"
  row_file[$name]=$rpm_file

  checksum=$(sha256sum "$rpm_file") || fail "cannot checksum $rpm_file"
  row_checksum[$name]=${checksum%% *}

  # Red Hat publishes each file at
  # <repository>/Packages/<first letter of the file name, lower case>/<file>.
  cache_folder=${rpm_file%/packages/*}
  cache_folder=${cache_folder##*/}
  repository=${cache_folder%"-9-$arch"}
  file_name=${rpm_file##*/}
  first_letter=${file_name:0:1}
  # "|| exit 1": the function's own fail ran inside "$( ... )" and could
  # only end that subshell.
  row_address[$name]="$(repository_address "$repository")" \
    || exit 1
  row_address[$name]+="/Packages/${first_letter,,}/$file_name"

  row_newest[$name]=$(newest_file_date "$rpm_file") || exit 1
done

(( ${#row_package[@]} > 0 )) || fail 'no RPM files were downloaded'

# Every package the build installs must have a row, or the lock is incomplete.
not_recorded=()
for name in "${!installed_all[@]}"; do
  [[ -n ${row_package[$name]} ]] || not_recorded+=("$name")
done
(( ${#not_recorded[@]} == 0 )) \
  || fail 'installed in the trial but no downloaded RPM file was found for:' \
          "${not_recorded[*]}"

# ---------------------------------------------------------------------------
# Step 6 of 6: replace held packages with their fixed versions
#
# build/held-rpms.<arch>.txt lists RPM files by checksum and address. Each one
# is downloaded, checked against its checksum, and then takes the place of the
# version the repository currently publishes under the same name.
# ---------------------------------------------------------------------------
echo "Step 6 of 6: applying held packages from $held_list"

declare -A held=()
for i in "${!held_addresses[@]}"; do
  checksum=${held_checksums[i]}
  address=${held_addresses[i]}
  held_file=$notes/${address##*/}
  curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
    --connect-timeout 30 --speed-limit 1 --speed-time 60 \
    --proto =https --globoff --output "$held_file" "$address" \
    || fail "cannot download the held file $address"
  file_checksum=$(sha256sum -- "$held_file") \
    || fail "cannot checksum $held_file"
  file_checksum=${file_checksum%% *}
  [[ $file_checksum == "${checksum,,}" ]] \
    || fail "checksum does not match the lock: ${held_file##*/} has" \
            "$file_checksum, the lock says $checksum"

  name=$(rpm --query --package --nosignature --queryformat '%{NAME}' \
    "$held_file") \
    || fail "rpm cannot read $held_file"
  held_package=$(rpm --query --package --nosignature \
    --queryformat '%{NEVRA}' "$held_file") \
    || fail "rpm cannot read $held_file"

  # Checked for every image, so a wrong line is found on the first run.
  [[ -z ${held[$name]} ]] || fail "$held_list holds '$name' twice"
  held[$name]=1
  # download-rpms.sh refuses a lock row for another architecture.
  held_arch=${held_package##*.}
  [[ $held_arch == "$arch" || $held_arch == noarch ]] \
    || fail "$held_list: $held_package is not built for $arch"

  # Only images that install this package need the held version.
  [[ -n ${row_package[$name]} ]] || continue

  row_package[$name]=$held_package
  row_checksum[$name]=$checksum
  row_address[$name]=$address
  row_newest[$name]=$(newest_file_date "$held_file") || exit 1
  row_file[$name]=$held_file
  echo "             held: ${row_package[$name]}"
done

transaction_root=$notes/transaction
mkdir --parents "$transaction_root" \
  || fail 'cannot create the final transaction test directory'
rpm --root="$transaction_root" --initdb \
  || fail 'rpm cannot initialize the final transaction test directory'
final_rpms=()
for name in "${!row_file[@]}"; do
  final_rpms+=("${row_file[$name]}")
done
if ! rpm --root="$transaction_root" --test --install --excludedocs \
    "${final_rpms[@]}" > "$notes/transaction.log" 2>&1; then
  tail --lines=20 -- "$notes/transaction.log" >&2 \
    || echo "generate-lock: cannot show rpm's output" >&2
  fail 'the exact locked RPM transaction cannot be installed'
fi

# ---------------------------------------------------------------------------
# Write the lock
# ---------------------------------------------------------------------------

# The newest file date across every RPM file in the lock.
source_date_epoch=0
for newest in "${row_newest[@]}"; do
  if (( newest > source_date_epoch )); then
    source_date_epoch=$newest
  fi
done

# Sorted by package name, so a refresh shows up as a small, readable diff.
names_text=$(printf '%s\n' "${!row_package[@]}" | sort) \
  || fail 'cannot sort the package names'
mapfile -t names <<< "$names_text"

ship_count=0
install_count=0

write_lock() {
  local name role
  cat <<EOF || return 1
# GENERATED by build/generate-lock.sh - do not edit.
#
# source-date-epoch: $source_date_epoch
#   The date of the newest file inside these RPM files, in seconds since 1970.
#   The build gives this date to every file it creates itself, so the same
#   lock always produces the same image. build/build-image.sh reads this line.
#
# One line per RPM file installed while this image is built:
#   package | sha256 checksum | download address | role
# role: ship    = stays in the finished image
#       install = needed only while building; removed before the image is
#                 finished
EOF
  for name in "${names[@]}"; do
    if [[ -n ${ships[$name]} ]]; then
      role=ship
      ((ship_count++))
    else
      role=install
      ((install_count++))
    fi
    printf '%s|%s|%s|%s\n' "${row_package[$name]}" "${row_checksum[$name]}" \
      "${row_address[$name]}" "$role" || return 1
  done
}

# Write the whole lock beside the real one first, so a failure half-way cannot
# leave a half-written lock in its place.
lock_in_progress=$(mktemp "$lock_file.XXXXXX") \
  || fail "cannot create a temporary file beside $lock_file"
write_lock > "$lock_in_progress" || fail "cannot write $lock_file"
chmod 0644 "$lock_in_progress" || fail "cannot set the mode of $lock_file"
mv -- "$lock_in_progress" "$lock_file" || fail "cannot replace $lock_file"
lock_in_progress=''

echo "Wrote $lock_file: $ship_count ship, $install_count install-only."
