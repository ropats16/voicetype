# Parakeet model table for the shell scripts (sourced, not run). It mirrors
# the app's catalog (Sources/VoiceType/Transcription/ParakeetCatalog.swift) —
# ids, repos, pinned revisions, and every file's SHA-256 and size — and
# ParakeetCatalogScriptParityTests fails if the two drift.
#
# Models live in <models>/parakeet/<id>/ (models dir: see model_catalog.sh).

# shellcheck source=model_catalog.sh
source "$(dirname "${BASH_SOURCE[0]}")/model_catalog.sh"
VOICETYPE_PARAKEET_DIR="$VOICETYPE_MODELS_DIR/parakeet"

# id  repo  revision
# BEGIN PARAKEET MODELS
PARAKEET_MODELS="
parakeet-tdt-0.6b-v3 FluidInference/parakeet-tdt-0.6b-v3-coreml 7dd20fe6b1797d35f5e3307e8b1732d9a178edfe
"
# END PARAKEET MODELS

# id  path  sha256  bytes   (path relative to the model folder and repo root)
# BEGIN PARAKEET FILES
PARAKEET_FILES="
parakeet-tdt-0.6b-v3 parakeet_vocab.json 7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735 151122
parakeet-tdt-0.6b-v3 Preprocessor.mlmodelc/analytics/coremldata.bin c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d 243
parakeet-tdt-0.6b-v3 Preprocessor.mlmodelc/coremldata.bin dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d 486
parakeet-tdt-0.6b-v3 Preprocessor.mlmodelc/metadata.json 2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf 2841
parakeet-tdt-0.6b-v3 Preprocessor.mlmodelc/model.mil 4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93 28181
parakeet-tdt-0.6b-v3 Preprocessor.mlmodelc/weights/weight.bin 129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea 491072
parakeet-tdt-0.6b-v3 Encoder.mlmodelc/analytics/coremldata.bin 42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105 243
parakeet-tdt-0.6b-v3 Encoder.mlmodelc/coremldata.bin d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86 485
parakeet-tdt-0.6b-v3 Encoder.mlmodelc/metadata.json da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9 2921
parakeet-tdt-0.6b-v3 Encoder.mlmodelc/model.mil ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808 959769
parakeet-tdt-0.6b-v3 Encoder.mlmodelc/weights/weight.bin e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421 445187200
parakeet-tdt-0.6b-v3 Decoder.mlmodelc/analytics/coremldata.bin 4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350 243
parakeet-tdt-0.6b-v3 Decoder.mlmodelc/coremldata.bin 18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99 554
parakeet-tdt-0.6b-v3 Decoder.mlmodelc/metadata.json a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9 3427
parakeet-tdt-0.6b-v3 Decoder.mlmodelc/model.mil ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35 13110
parakeet-tdt-0.6b-v3 Decoder.mlmodelc/weights/weight.bin 48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41 23604992
parakeet-tdt-0.6b-v3 JointDecisionv3.mlmodelc/analytics/coremldata.bin 26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c 243
parakeet-tdt-0.6b-v3 JointDecisionv3.mlmodelc/coremldata.bin f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342 521
parakeet-tdt-0.6b-v3 JointDecisionv3.mlmodelc/metadata.json d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f 3453
parakeet-tdt-0.6b-v3 JointDecisionv3.mlmodelc/model.mil be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d 11775
parakeet-tdt-0.6b-v3 JointDecisionv3.mlmodelc/weights/weight.bin 4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e 12642764
"
# END PARAKEET FILES

PARAKEET_DEFAULT_MODEL="parakeet-tdt-0.6b-v3"

# parakeet_model_field <id> <2=repo|3=revision> — prints the field, or fails for an unknown id.
parakeet_model_field() {
  local row
  row="$(awk -v id="$1" '$1 == id { print $'"$2"' }' <<<"$PARAKEET_MODELS")"
  [[ -n "$row" ]] || return 1
  printf '%s' "$row"
}

# parakeet_files <id> — prints "path sha256 bytes" per file.
parakeet_files() {
  awk -v id="$1" '$1 == id { print $2, $3, $4 }' <<<"$PARAKEET_FILES"
}

# The known ids, space-separated (for usage/error messages).
parakeet_model_ids() {
  awk 'NF { printf "%s%s", sep, $1; sep = " " }' <<<"$PARAKEET_MODELS"
}
