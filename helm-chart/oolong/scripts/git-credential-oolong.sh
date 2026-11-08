# Git credential helper for the Git pod (POSIX sh, builtins only).
# Run by git as: /bin/sh git-credential-oolong.sh <auth-dir> <action>
# Prints the user name and token read from <auth-dir>/username and <auth-dir>/token.
# Neither value is ever an argument of an executed program, and nothing is stored.

_dir="$1"
_action="$2"

# git can never make this helper persist or forget anything.
if [ "$_action" != "get" ]; then
  exit 0
fi

# Read and discard git's request (up to the blank line).
while IFS= read -r _request_line; do
  [ -z "$_request_line" ] && break
done

_cr="$(printf '\r')"

# Read the one line of a file into _value. A trailing newline is optional. A second line, a
# carriage return or an empty value is refused, so a malformed Secret cannot add attributes
# (url=, host=) to git's credential protocol. The message names the file, never its content.
read_single_line() {
  _file="$1"
  _value=""
  _extra=""
  if [ ! -r "$_file" ]; then
    echo "ERROR: $_file is missing, empty or not a single line" >&2
    return 1
  fi
  {
    IFS= read -r _value || :
    if IFS= read -r _extra; then
      _value=""
    elif [ -n "$_extra" ]; then
      _value=""
    fi
  } < "$_file"
  case "$_value" in
    '' | *"$_cr"*)
      _value=""
      echo "ERROR: $_file is missing, empty or not a single line" >&2
      return 1
      ;;
  esac
  return 0
}

read_single_line "$_dir/username" || exit 1
_user="$_value"
read_single_line "$_dir/token" || exit 1
_token="$_value"

printf 'username=%s\n' "$_user"
printf 'password=%s\n' "$_token"
