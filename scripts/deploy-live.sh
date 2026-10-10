#!/usr/bin/env bash
# Commit-only, allowlisted deployment. Remote mutations share one Bash/lock lifetime.
set -euo pipefail
umask 077
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
die() { printf 'HATA: %s\n' "$*" >&2; exit 2; }
info() { printf '%s\n' "$*"; }
progress() { printf '%s\n' "$*" >&2; }
usage() {
  cat <<'EOF'
deploy-live.sh --profile distribution|lisans --ref <commit|tag> --target <user@host:/abs/path>
               [--repo <path>] [--allowlist <file>] [--identity <path>] [--transport auto|tar]
               [--origin-branch <dal>] [--apply]
deploy-live.sh --profile distribution|lisans --rollback <backup-name> --target <user@host:/abs/path> [--apply]
Varsayilan DRY-RUN: uzakta kilit dahil hicbir sey yazilmaz. Servisler yeniden baslatilmaz.
--apply yalniz origin/main'den (ya da --origin-branch ile acikca verilen origin dalindan) erisilebilen commit'i
kabul eder; baska bir origin dalinda bulunmasi yetmez. village/* dallari hicbir zaman kabul edilmez.
EOF
}

# Case-insensitive hard deny; public trust anchors bypass ONLY the certificate rule.
DENY_GLOBS=(
  'update-server/www' 'update-server/www/**' 'channels' 'channels/**'
  '**/certs' '**/certs/**' '**/secrets' '**/secrets/**'
  '**/credentials' '**/credentials/**' '**/state' '**/state/**'
  '**/backups' '**/backups/**' '**/.git' '**/.git/**'
  '**/node_modules' '**/node_modules/**' '**/.env*' '**/create_user.py'
  '**/*.key' '**/*.pem' '**/*.p12' '**/*.pfx' '**/*.jks' '**/*.keystore'
  '**/id_rsa*' '**/id_ed25519*' '**/id_ecdsa*' '**/*.minisign' '**/minisign.key' '**/*.sec'
  '**/.htpasswd' '**/*.sql' '**/*.sql.gz' '**/*.dump'
  '**/.deploy-backups' '**/.deploy-backups/**' '**/.deploy-staging' '**/.deploy-staging/**'
  '**/.deploy-lock' '**/.deploy-lock/**' '**/.deploy-incomplete*' '**/.deployed-commit*'
)
CERT_GLOBS=('**/*.crt' '**/*.cer')
PUBLIC_TRUST_ANCHORS=('public-keys/*.pub' 'deployment/**/ca/*.crt' 'deployment/**/*.pub')
glob_to_regex() {
  local g=$1 out='^' i c len=${#1}
  for ((i=0; i<len; i++)); do
    c=${g:i:1}
    case $c in
      '*')
        if [[ ${g:i:3} == '**/' ]]; then out+='(.*/)?'; i=$((i+2))
        elif [[ ${g:i:2} == '**' ]]; then out+='.*'; i=$((i+1))
        else out+='[^/]*'; fi ;;
      '?') out+='[^/]' ;;
      '.'|'+'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|'|'\') out+="\\$c" ;;
      *) out+=$c ;;
    esac
  done
  GLOB_REGEX="$out"'$'
}
declare -A GLOB_CACHE=()
compile_patterns() {
  local g
  PATTERN_REGEX=''
  for g in "$@"; do
    if [[ ! ${GLOB_CACHE[$g]+yes} ]]; then glob_to_regex "$g"; GLOB_CACHE[$g]=$GLOB_REGEX; fi
    [[ -z $PATTERN_REGEX ]] || PATTERN_REGEX+='|'
    PATTERN_REGEX+="(${GLOB_CACHE[$g]})"
  done
}
matches() {
  local path=$1 g; shift
  for g in "$@"; do
    if [[ ! ${GLOB_CACHE[$g]+yes} ]]; then glob_to_regex "$g"; GLOB_CACHE[$g]=$GLOB_REGEX; fi
    [[ $path =~ ${GLOB_CACHE[$g]} ]] && return 0
  done
  return 1
}
is_denied() {
  local LC_ALL=C
  local path=${1,,}
  if [[ $PROFILE == lisans ]]; then
    case $path in docker-compose.yml|version|.env*|create_user.py) return 0 ;; esac
  fi
  [[ $path =~ $DENY_REGEX ]] && return 0
  if [[ $path =~ $CERT_REGEX ]]; then
    [[ $1 =~ $ANCHOR_REGEX ]] || return 0
  fi
  return 1
}
compile_patterns "${DENY_GLOBS[@]}"; DENY_REGEX=$PATTERN_REGEX
compile_patterns "${CERT_GLOBS[@]}"; CERT_REGEX=$PATTERN_REGEX
compile_patterns "${PUBLIC_TRUST_ANCHORS[@]}"; ANCHOR_REGEX=$PATTERN_REGEX
valid_path() {
  [[ -n $1 && $1 != /* && $1 != */ && $1 != *\\* && $1 != *[[:cntrl:]]* ]] || die "gecersiz dosya yolu: $1"
  case /$1/ in *'/../'*|*'/./'*|*'//'*) die "guvensiz dosya yolu: $1" ;; esac
}
quote() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }
rollback_command() {
  printf 'scripts/deploy-live.sh --profile %s --rollback %s --target %s:%s' "$PROFILE" "$(quote "$1")" "$USERHOST" "$T"
  if [[ -n $IDENTITY ]]; then printf ' --identity %s' "$(quote "$IDENTITY")"; fi
  printf ' --apply'
}

REF='' TARGET='' PROFILE='' ALLOWLIST='' IDENTITY='' REPO='' ROLLBACK='' APPLY=0 TRANSPORT=auto WORK='' ORIGIN_BRANCH=main
while (($#)); do
  case $1 in
    --apply) APPLY=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --ref|--target|--profile|--allowlist|--identity|--repo|--rollback|--transport|--origin-branch)
      (($#>=2)) || die "$1 deger ister"
      case $1 in
        --ref) REF=$2 ;; --target) TARGET=$2 ;; --profile) PROFILE=$2 ;;
        --allowlist) ALLOWLIST=$2 ;; --identity) IDENTITY=$2 ;; --repo) REPO=$2 ;;
        --rollback) ROLLBACK=$2 ;; --transport) TRANSPORT=$2 ;; --origin-branch) ORIGIN_BRANCH=$2 ;;
      esac; shift 2 ;;
    *) die "bilinmeyen arguman: $1" ;;
  esac
done
case $PROFILE in distribution|lisans) ;; *) die '--profile distribution|lisans zorunlu' ;; esac
# Reviewed work lives on origin/main. Another origin branch must be named on purpose; agent branches never qualify.
[[ $ORIGIN_BRANCH =~ ^[A-Za-z0-9._/-]+$ && $ORIGIN_BRANCH != -* && $ORIGIN_BRANCH != *..* && $ORIGIN_BRANCH != */ ]] || die 'gecersiz --origin-branch'
[[ $ORIGIN_BRANCH != village && $ORIGIN_BRANCH != village/* ]] || die '--origin-branch village/* olamaz: incelenmemis is dagitilmaz'
[[ $TARGET == *:* ]] || die '--target user@host:/mutlak/yol zorunlu'
USERHOST=${TARGET%%:*}; T=${TARGET#*:}
target_re='^[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+$'
[[ $USERHOST =~ $target_re ]] || die 'gecersiz user@host'
[[ $T =~ ^/[A-Za-z0-9._/+@=,-]+$ ]] || die 'gecersiz mutlak hedef yol'
T=${T%/}
valid_path "${T#/}"
[[ ${T##*/} == "$PROFILE" && ${T#/} == */* ]] || die 'profil ile hedef yolun son bileseni uyusmuyor'
case $TRANSPORT in auto|tar) TRANSPORT=tar ;; rsync) die 'guvenli tek oturum aktarimi icin --transport tar kullanin' ;; *) die 'gecersiz transport' ;; esac
if [[ -n $ROLLBACK ]]; then
  [[ -z $REF && $ROLLBACK =~ ^[0-9]{8}T[0-9]{6}Z-([0-9a-f]{7,40}|none)-[0-9a-f]{16}$ ]] || die 'gecersiz rollback adi veya --ref'
else
  [[ -n $REF && $REF != -* && $REF =~ ^[A-Za-z0-9._/@^~-]+$ ]] || die '--ref zorunlu/gecersiz'
fi
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15)
if [[ -n $IDENTITY ]]; then
  [[ $IDENTITY != *[[:cntrl:]]* && -f $IDENTITY ]] || die 'identity dosyasi bulunamadi/gecersiz yol'
  # A forward-slash Windows path works with both Git OpenSSH and native OpenSSH.
  if command -v cygpath >/dev/null 2>&1; then IDENTITY=$(cygpath -am "$IDENTITY"); fi
  SSH_OPTS+=(-o IdentitiesOnly=yes -i "$IDENTITY")
fi
rssh() {
  local encoded loader stream=${2:-0}
  # Frame the script before the tar stream: native Windows SSH has an argv size limit.
  # Decode only in memory; dry-run requires no remote temporary script or other write.
  encoded=$(printf '%s' "$1" | base64 -w0)
  loader='IFS= read -r payload; script=$(printf "%s" "$payload" | base64 --decode); eval "$script"'
  {
    printf '%s\n' "$encoded"
    if ((stream)); then cat; fi
  } | MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' ssh "${SSH_OPTS[@]}" -- "$USERHOST" "bash -euo pipefail -c $(quote "$loader")"
}
cleanup() { if [[ -n $WORK ]]; then rm -rf -- "$WORK" || printf 'HATA: yerel temizlik basarisiz: %s\n' "$WORK" >&2; fi; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# Shared policy is sent to remote Bash, including rollback. No dependency on remote Python.
REMOTE_COMMON=$(cat <<'EOF'
# Control directories use a separate 077 umask; files have explicit Git modes.
umask 022
check_dir() {
  local path=$1 cur='' c
  local -a parts
  IFS=/ read -r -a parts <<<"$path"
  for c in "${parts[@]}"; do
    [[ -n $c ]] || continue
    cur+=/$c
    [[ ! -L $cur ]] || die "symlink dizin reddedildi: $cur"
    if [[ -e $cur ]]; then [[ -d $cur ]] || die "dizin degil: $cur"; fi
  done
}
check_file() {
  check_dir "${1%/*}"
  [[ ! -L $1 ]] || die "symlink dosya reddedildi: $1"
  if [[ -e $1 ]]; then [[ -f $1 ]] || die "normal dosya degil: $1"; fi
}

measure_files() {
  local p hashes stats line mode size
  MEASURE_HASH=(); MEASURE_MODE=(); MEASURE_SIZE=()
  (($#)) || return 0
  for p in "$@"; do check_file "$p"; [[ -f $p ]] || die "dosya eksik: $p"; done
  # Keep results in memory: the read-only plan/rollback must not write temporary files.
  hashes=$(printf '%s\0' "$@" | xargs -0 -r sha256sum --)
  stats=$(printf '%s\0' "$@" | xargs -0 -r stat -c $'%a\t%s' --)
  while IFS= read -r line; do
    line=${line%% *}; [[ $line =~ ^[0-9a-f]{64}$ ]] || die 'gecersiz toplu hash'
    MEASURE_HASH+=("$line")
  done <<<"$hashes"
  while IFS=$'\t' read -r mode size; do
    [[ $mode =~ ^[0-7]{3,4}$ && $size =~ ^[0-9]+$ ]] || die 'gecersiz toplu mod/boyut'
    MEASURE_MODE+=("$mode"); MEASURE_SIZE+=("$size")
  done <<<"$stats"
  [[ ${#MEASURE_HASH[@]} == $# && ${#MEASURE_MODE[@]} == $# ]] || die 'toplu dosya dogrulama sonucu eksik'
}
verify_measured() {
  local i=$1 p=$2 h=$3 mode=$4 size=$5
  # measure_files has already checked every path before reading its bytes/metadata.
  [[ ${MEASURE_HASH[$i]} == "$h" && ${MEASURE_MODE[$i]} == "$mode" && ${MEASURE_SIZE[$i]} == "$size" ]] || die "hash/mod/boyut uyusmuyor: $p (beklenen $h/$mode/$size; gercek ${MEASURE_HASH[$i]}/${MEASURE_MODE[$i]}/${MEASURE_SIZE[$i]})"
}
verify_candidates() {
  local root=$1 i j=0; shift
  local -a paths=()
  for i in "$@"; do paths+=("$root/${FILES[$i]}"); done
  measure_files "${paths[@]}"
  for i in "$@"; do
    verify_measured "$j" "$root/${FILES[$i]}" "${HASHES[$i]}" "${MODES[$i]}" "${SIZES[$i]}"
    j=$((j+1))
  done
}
apply_modes() {
  local root=$1 i; shift
  local -a mode644=() mode755=()
  for i in "$@"; do
    check_file "$root/${FILES[$i]}"
    case ${MODES[$i]} in
      644) mode644+=("$root/${FILES[$i]}") ;;
      755) mode755+=("$root/${FILES[$i]}") ;;
      *) die 'gecersiz Git dosya modu' ;;
    esac
  done
  if ((${#mode644[@]})); then printf '%s\0' "${mode644[@]}" | xargs -0 -r chmod 644 --; fi
  if ((${#mode755[@]})); then printf '%s\0' "${mode755[@]}" | xargs -0 -r chmod 755 --; fi
}
preflight() {
  check_dir "$T"; [[ -d $T ]] || die "hedef dizin yok: $T"
  local d f listing
  for d in .deploy-backups .deploy-staging .deploy-lock; do check_dir "$T/$d"; done
  for f in .deployed-commit .deployed-commit.prev .deployed-commit.new .deploy-incomplete .deploy-lock/token .deploy-lock/info; do check_file "$T/$f"; done
  # Refuse pre-existing symlinks/special files anywhere in control trees, before lock writes.
  for d in .deploy-backups .deploy-staging .deploy-lock; do
    if [[ -d $T/$d ]]; then
      listing=$(find "$T/$d" -mindepth 1 ! -type d ! -type f -print)
      [[ -z $listing ]] || die "symlink/ozel dosya kontrol agacinda: $listing"
    fi
  done
}
incomplete_message() {
  local b
  b=$(cat -- "$T/.deploy-incomplete")
  die "yarida kesilmis dagitim: $b; rollback komutu: $(rollback_command "$b")"
}
EOF
)
REMOTE_MUTATION=$(cat <<'EOF'
make_dir() {
  local path=$1 cur='' c
  local -a parts
  check_dir "$path"
  IFS=/ read -r -a parts <<<"$path"
  for c in "${parts[@]}"; do
    [[ -n $c ]] || continue
    cur+=/$c
    check_dir "$cur"
    if [[ ! -d $cur ]]; then
      case $cur in
        "$T"/.deploy-backups|"$T"/.deploy-backups/*|"$T"/.deploy-staging|"$T"/.deploy-staging/*)
          (umask 077; mkdir -- "$cur") ;;
        *) mkdir -- "$cur" ;;
      esac
    fi
    check_dir "$cur"
  done
}
L="$T/.deploy-lock"
held=0
release_lock() {
  local rc=$?
  trap - EXIT
  if ((held)); then
    check_file "$L/token"
    if [[ -f $L/token && $(cat -- "$L/token") == "$TOKEN" ]]; then
      rm -- "$L/token" || { printf 'HATA: kilit token temizligi basarisiz\n' >&2; rc=1; }
      rmdir -- "$L" || { printf 'HATA: kilit temizligi basarisiz: %s\n' "$L" >&2; rc=1; }
    else
      printf 'HATA: kilit sahipligi degisti; kilit korunuyor\n' >&2; rc=1
    fi
  fi
  if ((rc)) && [[ -f $T/.deploy-incomplete ]]; then
    printf 'HATA: islem tamamlanmadi; rollback: %s\n' "$(rollback_command "$(cat -- "$T/.deploy-incomplete")")" >&2
  fi
  exit "$rc"
}
acquire_lock() {
  check_dir "$L"
  trap release_lock EXIT
  # Avoid a catchable signal between successful mkdir and ownership registration.
  trap '' INT TERM HUP
  if ! (umask 077; mkdir -- "$L"); then die "uzak kilit mevcut: $L; calisan islemi kontrol edin, otomatik kaldirilmaz"; fi
  held=1
  check_file "$L/token"
  printf '%s\n' "$TOKEN" > "$L/token"
  chmod 600 -- "$L/token"
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  preflight
}
write_marker() { check_file "$T/.deploy-incomplete"; printf '%s\n' "$BNAME" > "$T/.deploy-incomplete"; }
finish_marker() { check_file "$T/.deploy-incomplete"; rm -- "$T/.deploy-incomplete"; }
EOF
)
remote_header() {
  declare -p T USERHOST PROFILE IDENTITY DENY_GLOBS CERT_GLOBS PUBLIC_TRUST_ANCHORS GLOB_CACHE DENY_REGEX CERT_REGEX ANCHOR_REGEX
  declare -f die info progress glob_to_regex matches is_denied valid_path quote rollback_command
  printf '%s\n' "$REMOTE_COMMON"
}
TOKEN=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
[[ $TOKEN =~ ^[0-9a-f]{32}$ ]] || die 'rastgele sahiplik token uretilemedi'

if [[ -n $ROLLBACK ]]; then
  REMOTE_ROLLBACK=$(cat <<'EOF'
B="$T/.deploy-backups/$ROLLBACK"
BNAME=$ROLLBACK
validate_backup() {
  local h mode size p extra listing kind parent j
  local -a paths=() expected_hash=() expected_mode=() expected_size=() new_paths=() new_members=()
  check_dir "$B"; [[ -d $B && $(realpath -e -- "$B") == "$T/.deploy-backups/$ROLLBACK" ]] || die 'yedek gercek yolu hedef kok altinda degil'
  check_file "$B/MANIFEST.sha256"; [[ -f $B/MANIFEST.sha256 ]] || die 'manifest eksik'
  declare -gA MEMBERS=() DIRS=([files]=1) RESTORE_HASH=() RESTORE_MODE=() RESTORE_SIZE=()
  while IFS=$'\t' read -r h mode size p extra; do
    [[ $h =~ ^[0-9a-f]{64}$ && $mode =~ ^[0-7]{3,4}$ && $size =~ ^[0-9]+$ && -n $p && -z $extra ]] || die 'gecersiz manifest satiri'
    valid_path "$p"
    [[ ! ${MEMBERS[$p]+yes} && $p != MANIFEST.sha256 ]] || die 'tekrarli/gecersiz manifest uyesi'
    case $p in
      files/*) valid_path "${p#files/}"; is_denied "${p#files/}" && die "rollback deny: $p"
        RESTORE_HASH[${p#files/}]=$h; RESTORE_MODE[${p#files/}]=$mode; RESTORE_SIZE[${p#files/}]=$size ;;
      NEW-FILES|PREVIOUS-STAMP|STAMP-PRESENT|NEW-DIRS) ;;
      *) die "manifest disi metadata: $p" ;;
    esac
    paths+=("$B/$p"); expected_hash+=("$h"); expected_mode+=("$mode"); expected_size+=("$size")
    MEMBERS[$p]=1
    parent=$p
    while [[ $parent == */* ]]; do parent=${parent%/*}; DIRS[$parent]=1; done
  done < "$B/MANIFEST.sha256"
  measure_files "${paths[@]}"
  for j in "${!paths[@]}"; do verify_measured "$j" "${paths[$j]}" "${expected_hash[$j]}" "${expected_mode[$j]}" "${expected_size[$j]}"; done
  for p in NEW-FILES PREVIOUS-STAMP STAMP-PRESENT NEW-DIRS; do [[ ${MEMBERS[$p]+yes} ]] || die "metadata eksik: $p"; done
  listing=$(find "$B" -mindepth 1 -printf '%P\t%y\n')
  while IFS=$'\t' read -r p kind extra; do
    valid_path "$p"
    [[ -z $extra ]] || die 'gecersiz yedek uyesi'
    case $kind in
      f) [[ $p == MANIFEST.sha256 || ${MEMBERS[$p]+yes} ]] || die "manifest disi uye: $p" ;;
      d) [[ ${DIRS[$p]+yes} ]] || die "manifest disi dizin: $p" ;;
      *) die "yedekte symlink/ozel dosya: $p" ;;
    esac
  done <<<"$listing"
  declare -gA NEW_HASH=() NEW_MODE=() NEW_SIZE=()
  while IFS=$'\t' read -r h mode size p extra; do
    [[ $h =~ ^[0-9a-f]{64}$ && $mode =~ ^[0-7]{3,4}$ && $size =~ ^[0-9]+$ && -n $p && -z $extra ]] || die 'gecersiz NEW-FILES'
    valid_path "$p"; is_denied "$p" && die "rollback deny: $p"
    [[ ! ${NEW_HASH[$p]+yes} && ! ${RESTORE_HASH[$p]+yes} ]] || die 'celisen NEW-FILES'
    check_file "$T/$p"
    if [[ -f $T/$p ]]; then new_paths+=("$T/$p"); new_members+=("$p"); fi
    NEW_HASH[$p]=$h; NEW_MODE[$p]=$mode; NEW_SIZE[$p]=$size
  done < "$B/NEW-FILES"
  measure_files "${new_paths[@]}"
  for j in "${!new_paths[@]}"; do
    p=${new_members[$j]}
    [[ ${MEASURE_HASH[$j]} == "${NEW_HASH[$p]}" ]] || die "yeni dosya degismis; silinmeyecek: $p"
  done
  for p in "${!RESTORE_HASH[@]}"; do check_file "$T/$p"; done
  while IFS= read -r p; do valid_path "$p"; is_denied "$p" && die "rollback dizin deny: $p"; check_dir "$T/$p"; done < "$B/NEW-DIRS"
  present=$(cat -- "$B/STAMP-PRESENT")
  [[ $present == 0 || $present == 1 ]] || die 'bozuk STAMP-PRESENT'
  if [[ $present == 0 ]]; then [[ ! -s $B/PREVIOUS-STAMP ]] || die 'celisen onceki damga'; fi
  info 'yedek butunlugu ve dosya kumesi: OK'
}
preflight
if [[ -f $T/.deploy-incomplete && $(cat -- "$T/.deploy-incomplete") != "$ROLLBACK" ]]; then incomplete_message; fi
validate_backup
EOF
)
  remote="$(remote_header)
$(declare -p ROLLBACK TOKEN)
$REMOTE_ROLLBACK"
  if ((APPLY)); then
    remote+=$'\n'"$REMOTE_MUTATION"$'\n'"$(cat <<'EOF'
acquire_lock
validate_backup
write_marker
progress 'aktarim: rollback...'
S="$T/.deploy-staging/rollback-$TOKEN"
check_dir "$S"; [[ ! -e $S ]] || die 'staging mevcut'
make_dir "$S"
restore_paths=()
for p in "${!RESTORE_HASH[@]}"; do
  dest="$S/$p"; make_dir "${dest%/*}"; check_file "$S/$p"
  cp -p -- "$B/files/$p" "$S/$p"
  restore_paths+=("$p")
done
stage_paths=(); for p in "${restore_paths[@]}"; do stage_paths+=("$S/$p"); done
measure_files "${stage_paths[@]}"
for j in "${!restore_paths[@]}"; do p=${restore_paths[$j]}; verify_measured "$j" "$S/$p" "${RESTORE_HASH[$p]}" "${RESTORE_MODE[$p]}" "${RESTORE_SIZE[$p]}"; done
target_paths=()
for p in "${restore_paths[@]}"; do
  dest="$T/$p"; check_file "$dest"; make_dir "${dest%/*}"
  mv -T -- "$S/$p" "$T/$p"
  target_paths+=("$T/$p")
done
measure_files "${target_paths[@]}"
for j in "${!restore_paths[@]}"; do p=${restore_paths[$j]}; verify_measured "$j" "$T/$p" "${RESTORE_HASH[$p]}" "${RESTORE_MODE[$p]}" "${RESTORE_SIZE[$p]}"; done
new_paths=(); new_members=()
for p in "${!NEW_HASH[@]}"; do
  check_file "$T/$p"
  if [[ -f $T/$p ]]; then new_paths+=("$T/$p"); new_members+=("$p"); fi
done
measure_files "${new_paths[@]}"
for j in "${!new_paths[@]}"; do
  p=${new_members[$j]}; check_file "$T/$p"
  [[ ${MEASURE_HASH[$j]} == "${NEW_HASH[$p]}" ]] || die "yeni dosya degismis: $p"
  rm -- "$T/$p"
done
# Remove only empty directories created by this deployment; preserve later user data.
dirs=$(LC_ALL=C sort -r -- "$B/NEW-DIRS")
if [[ -n $dirs ]]; then
  while IFS= read -r p; do
    check_dir "$T/$p"
    if [[ -d $T/$p ]]; then
      children=$(find "$T/$p" -mindepth 1 -maxdepth 1 -print)
      if [[ -z $children ]]; then rmdir -- "$T/$p"; fi
    fi
  done <<<"$dirs"
fi
check_file "$T/.deployed-commit"
if [[ $present == 1 ]]; then
  check_file "$T/.deployed-commit.new"
  check_file "$S/STAMP"
  cp -p -- "$B/PREVIOUS-STAMP" "$S/STAMP"
  mv -T -- "$S/STAMP" "$T/.deployed-commit.new"
  mv -T -- "$T/.deployed-commit.new" "$T/.deployed-commit"
else
  if [[ -f $T/.deployed-commit ]]; then rm -- "$T/.deployed-commit"; fi
fi
check_dir "$S"; rm -r -- "$S"
finish_marker
info 'ROLLBACK tamam: onceki dosyalar, modlar ve damga geri dondu; yeni dosyalar silindi'
EOF
)"
  else remote+=$'\n'"info 'DRY-RUN: uzakta hicbir sey degismedi'"; fi
  progress 'uzak plan: rollback dogrulama...'
  rssh "$remote"
  progress 'rollback dogrulama/islem tamam'
  exit 0
fi

ROOT=$(git -C "${REPO:-$SCRIPT_DIR}" rev-parse --show-toplevel) || die 'kaynak git deposu bulunamadi'
SHA=$(git -C "$ROOT" rev-parse --verify "${REF}^{commit}") || die 'ref cozulemedi'
[[ $SHA =~ ^[0-9a-f]{40,64}$ ]] || die 'gecersiz kaynak sha'
if [[ -z $ALLOWLIST ]]; then
  case $PROFILE in
    distribution) ALLOWLIST="$SCRIPT_DIR/deploy-live.allowlist" ;;
    lisans) ALLOWLIST="$SCRIPT_DIR/deploy-live.lisans.allowlist" ;;
  esac
fi
[[ -f $ALLOWLIST ]] || die 'allowlist bulunamadi'
ALLOW_GLOBS=()
while IFS= read -r line || [[ -n $line ]]; do
  line=${line%$'\r'}; line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
  [[ -z $line || $line == \#* ]] && continue
  [[ $line != '**' && $line != '*' && $line != /* && $line != *..* && $line != *\\* ]] || die "allowlist deseni gecersiz: $line"
  ALLOW_GLOBS+=("$line")
done < "$ALLOWLIST"
((${#ALLOW_GLOBS[@]})) || die 'allowlist bos'
compile_patterns "${ALLOW_GLOBS[@]}"; ALLOW_REGEX=$PATTERN_REGEX
info "== deploy-live $([[ $APPLY == 1 ]] && echo APPLY || echo DRY-RUN) =="
info "sha: $SHA; profil: $PROFILE; hedef: $USERHOST:$T; aktarim yontemi: tar"
dirty=$(git -C "$ROOT" status --porcelain)
[[ -z $dirty ]] || info 'not: calisma agaci kirli; yalniz commit edilmis kaynak aktarilir'
if ((APPLY)); then git -C "$ROOT" fetch --prune origin || die 'origin fetch basarisiz'; fi
# Being on SOME origin branch is not enough: unreviewed branches (village/*, feature work) are pushed there too.
on_origin=0
if git -C "$ROOT" rev-parse -q --verify "refs/remotes/origin/$ORIGIN_BRANCH^{commit}" >/dev/null 2>&1 &&
   git -C "$ROOT" merge-base --is-ancestor "$SHA" "refs/remotes/origin/$ORIGIN_BRANCH"; then on_origin=1; fi
if ((!on_origin)); then
  if ((APPLY)); then die "commit origin/$ORIGIN_BRANCH dalindan erisilebilir degil"; fi
  printf 'UYARI: commit origin/%s dalinda bulunamadi; --apply reddedilir\n' "$ORIGIN_BRANCH" >&2
fi
LOCAL_START=$SECONDS
progress 'yerel dogrulama: dosya secimi...'
WORK=$(mktemp -d "${TMPDIR:-/tmp}/deploy-live.XXXXXX")
mkdir -- "$WORK/src"
git -C "$ROOT" ls-tree -r -z "$SHA" > "$WORK/tree"
FILES=() HASHES=() MODES=() SIZES=() BLOB_OIDS=()
while IFS= read -r -d '' rec; do
  meta=${rec%%$'\t'*}; path=${rec#*$'\t'}; mode=${meta%% *}
  # Deny is evaluated before user-controlled allowlist.
  if is_denied "$path"; then info "reddedildi: $path"; continue; fi
  [[ $path =~ $ALLOW_REGEX ]] || continue
  case $mode in 100644|100755) ;; *) info "symlink/submodule atlandi: $path"; continue ;; esac
  valid_path "$path"
  FILES+=("$path"); MODES+=("${mode#100}"); BLOB_OIDS+=("${meta##* }")
done < "$WORK/tree"
((${#FILES[@]})) || die 'aktarilacak dosya yok'
progress "yerel dogrulama: ${#FILES[@]} dosya..."
# --cached with an isolated index checks committed and info/attributes, without reading dirty files.
GIT_INDEX_FILE="$WORK/index" git -C "$ROOT" read-tree "$SHA"
GIT_INDEX_FILE="$WORK/index" git --literal-pathspecs -C "$ROOT" check-attr --cached -z export-ignore export-subst -- "${FILES[@]}" > "$WORK/attrs"
while IFS= read -r -d '' p && IFS= read -r -d '' attr && IFS= read -r -d '' value; do
  [[ $value == unspecified || $value == unset ]] || die "secili dosyada $attr yasak: $p"
done < "$WORK/attrs"
git --literal-pathspecs -C "$ROOT" -c core.autocrlf=false -c core.eol=lf archive --format=tar "$SHA" -- "${FILES[@]}" > "$WORK/source.tar"
tar -xpf "$WORK/source.tar" -C "$WORK/src"
find "$WORK/src" -mindepth 1 -printf '%P\0%y\0' > "$WORK/types"
declare -A ARCHIVE_TYPES=()
while IFS= read -r -d '' p && IFS= read -r -d '' kind; do ARCHIVE_TYPES[$p]=$kind; done < "$WORK/types"
exec 3> "$WORK/hash.paths" 4> "$WORK/batch.paths" 5> "$WORK/mode644" 6> "$WORK/mode755" 7> "$WORK/files.list"
for i in "${!FILES[@]}"; do
  p=${FILES[$i]}; [[ ${ARCHIVE_TYPES[$p]:-} == f ]] || die "arsiv uyesi eksik/normal degil: $p"
  # stdin-paths accepts Git C-quoted names; valid_path already excludes controls/backslashes.
  printf '"./%s"\n' "${p//\"/\\\"}" >&3
  printf './%s\0' "$p" >&4
  if [[ ${MODES[$i]} == 644 ]]; then printf './%s\0' "$p" >&5; else printf './%s\0' "$p" >&6; fi
  printf '%s\0' "$p" >&7
done
exec 3>&- 4>&- 5>&- 6>&- 7>&-
GIT_DIR=$(git -C "$ROOT" rev-parse --absolute-git-dir)
(
  cd "$WORK/src"
  # Use the source repository's object format, but never its filters or working tree.
  git --git-dir="$GIT_DIR" hash-object --no-filters --stdin-paths < "$WORK/hash.paths" > "$WORK/oids"
  xargs -0 -r sha256sum -- < "$WORK/batch.paths" > "$WORK/hashes"
  xargs -0 -r stat -c %s -- < "$WORK/batch.paths" > "$WORK/sizes"
  xargs -0 -r chmod 644 -- < "$WORK/mode644"
  xargs -0 -r chmod 755 -- < "$WORK/mode755"
)
mapfile -t ARCHIVE_OIDS < "$WORK/oids"
mapfile -t HASH_LINES < "$WORK/hashes"
mapfile -t SIZES < "$WORK/sizes"
[[ ${#ARCHIVE_OIDS[@]} == ${#FILES[@]} && ${#HASH_LINES[@]} == ${#FILES[@]} && ${#SIZES[@]} == ${#FILES[@]} ]] || die 'toplu dosya dogrulama sonucu eksik'
for i in "${!FILES[@]}"; do
  [[ ${ARCHIVE_OIDS[$i]} == "${BLOB_OIDS[$i]}" ]] || die "git blob / arsiv hash uyusmazligi: ${FILES[$i]}"
  h=${HASH_LINES[$i]%% *}
  [[ $h =~ ^[0-9a-f]{64}$ && ${SIZES[$i]} =~ ^[0-9]+$ ]] || die 'gecersiz toplu hash/boyut'
  HASHES+=("$h")
done
progress "yerel dogrulama tamam ($((SECONDS-LOCAL_START)) sn)"
progress 'uzak plan...'
REMOTE_PLAN=$(cat <<'EOF'
preflight
[[ ! -f $T/.deploy-incomplete ]] || incomplete_message
CHANGED=(); EXISTING=(); NEW=()
plan() {
  local i p h mode same=0 j=0
  local -a paths=()
  CHANGED=(); EXISTING=(); NEW=()
  # Validate EVERY candidate before any write, including lock creation.
  for p in "${FILES[@]}"; do
    if [[ -f $T/$p ]]; then paths+=("$T/$p"); else check_file "$T/$p"; fi
  done
  measure_files "${paths[@]}"
  for i in "${!FILES[@]}"; do
    p=${FILES[$i]}
    if [[ -f $T/$p ]]; then
      h=${MEASURE_HASH[$j]}; mode=${MEASURE_MODE[$j]}; j=$((j+1))
      if [[ $h == "${HASHES[$i]}" && $mode == "${MODES[$i]}" ]]; then same=$((same+1)); continue; fi
      EXISTING+=("$i"); info ">f.st...... $p"
    else NEW+=("$i"); info ">f+++++++++ $p"; fi
    CHANGED+=("$i")
    printf '@@TRANSFER\t%s\n' "$i"
  done
  info "degisecek mevcut dosya: ${#EXISTING[@]}, yeni dosya: ${#NEW[@]}, ayni: $same"
  progress 'uzak plan tamam'
}
plan
EOF
)
remote="$(remote_header)
$(declare -p FILES HASHES MODES SIZES SHA TOKEN)
$REMOTE_PLAN"
if ((!APPLY)); then
  remote+=$'\n'"info 'DRY-RUN: uzakta hicbir sey degismedi'"
  rssh "$remote"
  exit 0
fi
remote+=$'\n'"info 'salt-okunur on kontrol tamam'"
rssh "$remote" > "$WORK/plan"
cat -- "$WORK/plan"
TRANSFER=()
: > "$WORK/transfer.list"
while IFS=$'\t' read -r tag i extra; do
  [[ $tag == '@@TRANSFER' ]] || continue
  [[ $i =~ ^[0-9]+$ && -z $extra && ${FILES[$i]+yes} ]] || die 'gecersiz uzak aktarim plani'
  TRANSFER+=("$i")
  printf '%s\0' "${FILES[$i]}" >> "$WORK/transfer.list"
done < "$WORK/plan"
remote+=$'\n'"$(declare -p TRANSFER)"
remote+=$'\n'"$REMOTE_MUTATION"$'\n'"$(cat <<'EOF'
acquire_lock
[[ ! -f $T/.deploy-incomplete ]] || incomplete_message
plan
[[ ${CHANGED[*]} == "${TRANSFER[*]}" ]] || die 'hedef on kontrolden sonra degisti; tekrar dry-run yapin'
progress 'yedek...'
old=none; old_commit=none
if [[ -f $T/.deployed-commit ]]; then
  stamp=$(cat -- "$T/.deployed-commit")
  while IFS= read -r line; do if [[ $line =~ ^commit=([0-9a-f]{40,64})$ ]]; then old_commit=${BASH_REMATCH[1]}; old=${old_commit:0:12}; fi; done <<<"$stamp"
fi
BNAME="$(date -u +%Y%m%dT%H%M%SZ)-$old-${TOKEN:0:16}"
B="$T/.deploy-backups/$BNAME"
P="$B.partial"
S="$T/.deploy-staging/$TOKEN"
check_dir "$B"; check_dir "$P"; check_dir "$S"
[[ ! -e $B && ! -e $P && ! -e $S ]] || die 'yedek/staging zaten mevcut'
make_dir "$P/files"
: > "$P/NEW-FILES"; : > "$P/NEW-DIRS"
declare -A CREATED_DIRS=()
for i in "${CHANGED[@]}"; do
  p=${FILES[$i]}; parent=$p
  while [[ $parent == */* ]]; do
    parent=${parent%/*}
    if [[ ! -d $T/$parent && ! ${CREATED_DIRS[$parent]+yes} ]]; then
      CREATED_DIRS[$parent]=1; printf '%s\n' "$parent" >> "$P/NEW-DIRS"
    fi
  done
done
source_paths=(); backup_paths=()
for i in "${EXISTING[@]}"; do
  p=${FILES[$i]}; check_file "$T/$p"
  dest="$P/files/$p"; make_dir "${dest%/*}"
  cp -p -- "$T/$p" "$P/files/$p"
  source_paths+=("$T/$p"); backup_paths+=("$P/files/$p")
done
measure_files "${source_paths[@]}"
SOURCE_HASH=("${MEASURE_HASH[@]}"); SOURCE_MODE=("${MEASURE_MODE[@]}"); SOURCE_SIZE=("${MEASURE_SIZE[@]}")
measure_files "${backup_paths[@]}"
for j in "${!backup_paths[@]}"; do verify_measured "$j" "${backup_paths[$j]}" "${SOURCE_HASH[$j]}" "${SOURCE_MODE[$j]}" "${SOURCE_SIZE[$j]}"; done
for i in "${NEW[@]}"; do printf '%s\t%s\t%s\t%s\n' "${HASHES[$i]}" "${MODES[$i]}" "${SIZES[$i]}" "${FILES[$i]}" >> "$P/NEW-FILES"; done
if [[ -f $T/.deployed-commit ]]; then
  cp -p -- "$T/.deployed-commit" "$P/PREVIOUS-STAMP"; printf '1\n' > "$P/STAMP-PRESENT"
else : > "$P/PREVIOUS-STAMP"; printf '0\n' > "$P/STAMP-PRESENT"; fi
: > "$P/MANIFEST.sha256"
for j in "${!backup_paths[@]}"; do
  printf '%s\t%s\t%s\t%s\n' "${MEASURE_HASH[$j]}" "${MEASURE_MODE[$j]}" "${MEASURE_SIZE[$j]}" "files/${FILES[${EXISTING[$j]}]}" >> "$P/MANIFEST.sha256"
done
metadata=(NEW-FILES NEW-DIRS PREVIOUS-STAMP STAMP-PRESENT)
metadata_paths=(); for p in "${metadata[@]}"; do metadata_paths+=("$P/$p"); done
measure_files "${metadata_paths[@]}"
for j in "${!metadata[@]}"; do printf '%s\t%s\t%s\t%s\n' "${MEASURE_HASH[$j]}" "${MEASURE_MODE[$j]}" "${MEASURE_SIZE[$j]}" "${metadata[$j]}" >> "$P/MANIFEST.sha256"; done
mv -T -- "$P" "$B"
info "yedek tamam: $BNAME"
progress 'yedek tamam'
write_marker
progress 'aktarim...'
make_dir "$S"
check_file "$S/.in.tar"
cat > "$S/.in.tar"
# Listing is a separate checked operation; pipefail is active for all remote code.
tar -tf "$S/.in.tar" > "$S/.members"
tar -tvf "$S/.in.tar" > "$S/.types"
declare -A SEEN=() EXPECTED=()
for i in "${TRANSFER[@]}"; do EXPECTED[${FILES[$i]}]=1; done
while IFS= read -r p; do
  valid_path "$p"; is_denied "$p" && die "arsiv deny: $p"
  [[ ${EXPECTED[$p]+yes} && ! ${SEEN[$p]+yes} ]] || die "beklenmeyen/tekrarli arsiv uyesi: $p"
  SEEN[$p]=1
done < "$S/.members"
[[ ${#SEEN[@]} == ${#TRANSFER[@]} ]] || die 'arsiv uye sayisi uyusmuyor'
while IFS= read -r line; do [[ $line == -* ]] || die 'arsiv normal dosya disinda uye iceriyor'; done < "$S/.types"
make_dir "$S/files"
tar -xpf "$S/.in.tar" --no-same-owner -C "$S/files"
apply_modes "$S/files" "${TRANSFER[@]}"
progress 'dogrulama: staging...'
verify_candidates "$S/files" "${TRANSFER[@]}"
for i in "${CHANGED[@]}"; do
  p=${FILES[$i]}; check_file "$T/$p"
  dest="$T/$p"; make_dir "${dest%/*}"
  mv -T -- "$S/files/$p" "$T/$p"
done
progress 'aktarim tamam; dogrulama: hedef...'
verify_candidates "$T" "${!FILES[@]}"
progress 'dogrulama tamam'
check_file "$T/.deployed-commit.new"; check_file "$T/.deployed-commit"
check_file "$S/STAMP"
printf 'commit=%s\ndeployed_at=%s\nprevious=%s\n' "$SHA" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$old_commit" > "$S/STAMP"
chmod 644 -- "$S/STAMP"
mv -T -- "$S/STAMP" "$T/.deployed-commit.new"
mv -T -- "$T/.deployed-commit.new" "$T/.deployed-commit"
check_dir "$S"; rm -r -- "$S"
finish_marker
info "dagitim tamam: $SHA; rollback: $(rollback_command "$BNAME")"
info 'Servisler yeniden baslatilmadi; canli kabul ayri yapilmalidir.'
EOF
)"
# The archive carries only selected regular files. Only CHANGED files are moved remotely.
tar -cf - -C "$WORK/src" --null -T "$WORK/transfer.list" | rssh "$remote" 1
