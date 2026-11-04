# Shared model table for the shell scripts (sourced, not run). It mirrors the
# app's engine catalog (Sources/VoiceType/Transcription/ModelCatalog.swift) —
# ids, pinned SHA-256s, sizes, and the chip + RAM auto-pick — and
# ModelCatalogScriptParityTests fails if the two drift.
#
# Also the one rule for where models live, shared with the app's Paths.swift:
# a non-empty VOICETYPE_APP_SUPPORT replaces
# ~/Library/Application Support/VoiceType, and models go in its models/ folder.

VOICETYPE_SUPPORT_DIR="${VOICETYPE_APP_SUPPORT:-$HOME/Library/Application Support/VoiceType}"
VOICETYPE_MODELS_DIR="$VOICETYPE_SUPPORT_DIR/models"

# id  sha256  bytes   (file: ggml-<id>.bin on huggingface.co/ggerganov/whisper.cpp)
# BEGIN MODELS
VOICETYPE_MODELS="
tiny.en-q5_1         c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b 32166155
tiny.en-q8_0         5bc2b3860aa151a4c6e7bb095e1fcce7cf12c7b020ca08dcec0c6d018bb7dd94 43550795
tiny.en              921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f 77704715
tiny-q5_1            818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7 32152673
tiny-q8_0            c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca 43537433
tiny                 be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21 77691713
base.en-q5_1         4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f 59721011
base.en-q8_0         a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e 81781811
base.en              a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002 147964211
base-q5_1            422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898 59707625
base-q8_0            c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9 81768585
base                 60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe 147951465
small.en-q5_1        bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30 190098681
small.en-q8_0        67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067 264477561
small.en             c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d 487614201
small-q5_1           ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb 190085487
small-q8_0           49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f 264464607
small                1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b 487601967
medium.en-q5_0       76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0 539225533
medium.en-q8_0       43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c 823382461
medium.en            cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356 1533774781
medium-q5_0          19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f 539212467
medium-q8_0          42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502 823369779
medium               6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208 1533763059
large-v3-turbo-q5_0  394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2 574041195
large-v3-turbo-q8_0  317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1 874188075
large-v3-turbo       1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69 1624555275
large-v3-q5_0        d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1 1081140203
"
# END MODELS

# model_field <id> <2=sha256|3=bytes> — prints the field, or fails for an unknown id.
model_field() {
  local row
  row="$(awk -v id="$1" '$1 == id { print $'"$2"' }' <<<"$VOICETYPE_MODELS")"
  [[ -n "$row" ]] || return 1
  printf '%s' "$row"
}

# The known ids, space-separated (for usage/error messages).
model_ids() {
  awk 'NF { printf "%s%s", sep, $1; sep = " " }' <<<"$VOICETYPE_MODELS"
}

# recommended_model <arch> <whole-GiB RAM> — the app's auto-pick (English).
#   arm64:  <8 base.en-q5_1 | 8-15 small.en-q5_1 | 16-31 medium.en-q5_0 | >=32 medium.en-q8_0
#   x86_64: <8 tiny.en-q5_1 | 8-15 base.en-q5_1  | >=16 small.en-q5_1
recommended_model() {
  local arch=$1 gib=$2
  case "$arch" in
    arm64)
      if   (( gib >= 32 )); then printf 'medium.en-q8_0'
      elif (( gib >= 16 )); then printf 'medium.en-q5_0'
      elif (( gib >= 8 ));  then printf 'small.en-q5_1'
      else                       printf 'base.en-q5_1'
      fi
      ;;
    x86_64)
      if   (( gib >= 16 )); then printf 'small.en-q5_1'
      elif (( gib >= 8 ));  then printf 'base.en-q5_1'
      else                       printf 'tiny.en-q5_1'
      fi
      ;;
    *)
      echo "error: unsupported architecture '$arch' (expected arm64 or x86_64)." >&2
      return 1
      ;;
  esac
}
