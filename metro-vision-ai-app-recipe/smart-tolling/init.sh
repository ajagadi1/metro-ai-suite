#!/bin/bash

SOURCE="src"
if [ ! -f "${SOURCE}/secrets/browser.auth" ]; then
  bash ${SOURCE}/secrets/generate_secrets.sh
fi

# Required by the shared compose-scenescape.yml base's node-red secrets and settings.js adminAuth.
bash ${SOURCE}/secrets/generate_nodered_secret.sh

if [ ! -f .env ]; then
  touch .env
fi

USER_UID=$(stat -c '%u' "${SOURCE}"/* | sort -rn | head -1)
USER_GID=$(stat -c '%g' "${SOURCE}"/* | sort -rn | head -1)

echo "UID=$USER_UID" > .env
echo "GID=$USER_GID" >> .env

# This app ships without sample videos or scene data; both must be user-supplied (see docs/user-guide/get-started/bring-your-own-data.md).
VIDEO_DIR="${SOURCE}/dlstreamer-pipeline-server/videos"
VIDEOS=("FrontView_L_30fps.ts" "FrontView_R_30fps.ts" "RearView_L_30fps.ts" "RearView_R_30fps.ts" "SideAxle_Lane_1_30fps.ts" "SideAxle_Lane_2_30fps.ts")
MISSING_VIDEOS=()
for VIDEO in "${VIDEOS[@]}"; do
  if [ ! -f "${VIDEO_DIR}/${VIDEO}" ]; then
    MISSING_VIDEOS+=("${VIDEO}")
  fi
done
if [ ${#MISSING_VIDEOS[@]} -gt 0 ]; then
  echo "Error: Missing video file(s) in ${VIDEO_DIR}:"
  printf '  - %s\n' "${MISSING_VIDEOS[@]}"
  echo "See docs/user-guide/get-started/bring-your-own-data.md for what to provide."
  exit 1
fi

# Download models on demand (skip any model dir that already has a model.xml, e.g. from git).
MODELS_DIR="${SOURCE}/dlstreamer-pipeline-server/models"
MODEL_BRANCH="smart-city"
MODEL_URL="https://github.com/open-edge-platform/edge-ai-resources/raw/refs/heads/${MODEL_BRANCH}/models/INT8"
# local_dir:zip_name:folder_inside_zip
MODELS=(
  "axle:axle-detection.zip:axle-detection"
  "vehicle_type:vehicle-type-classification.zip:vehicle-type-classification"
  "vehicle_front_rear:vehicle-front-rear-detection.zip:vehicle-front-rear-detection"
  "color_int8_latest:vehicle-color-classification.zip:vehicle-color-classification"
  "licenseplate_cropped:licenseplate-detection.zip:licenseplate-detection"
)

for entry in "${MODELS[@]}"; do
  IFS=':' read -r local_dir zip_name zip_folder <<< "${entry}"
  if [ -f "${MODELS_DIR}/${local_dir}/model.xml" ]; then
    continue
  fi
  echo "Downloading model ${zip_name}..."
  tmp_zip="$(mktemp -d)/${zip_name}"
  if ! curl -f -L -s --retry 3 --retry-delay 2 --retry-all-errors "${MODEL_URL}/${zip_name}" -o "${tmp_zip}"; then
    echo "Error: Failed to download ${MODEL_URL}/${zip_name}"
    rm -rf "$(dirname "${tmp_zip}")"
    exit 1
  fi
  unzip -qo "${tmp_zip}" -d "$(dirname "${tmp_zip}")"
  mkdir -p "${MODELS_DIR}/${local_dir}"
  cp -r "$(dirname "${tmp_zip}")/${zip_folder}"/. "${MODELS_DIR}/${local_dir}/"
  chmod -R u+rwX "$(dirname "${tmp_zip}")" && rm -rf "$(dirname "${tmp_zip}")"
  if [ ! -f "${MODELS_DIR}/${local_dir}/model.xml" ]; then
    echo "Error: Failed to download model ${zip_name}"
    exit 1
  fi
done

# The OCR model is shared with the license-plate-reader bundle; reuse it rather than duplicating it.
if [ ! -f "${MODELS_DIR}/paddle_ocr_v4/ch_PP-OCRv4_rec_infer.xml" ]; then
  echo "Downloading model license-plate-reader.zip (OCR submodel)..."
  tmp_zip="$(mktemp -d)/license-plate-reader.zip"
  if ! curl -f -L -s --retry 3 --retry-delay 2 --retry-all-errors "https://github.com/open-edge-platform/edge-ai-resources/raw/refs/heads/${MODEL_BRANCH}/models/license-plate-reader.zip" -o "${tmp_zip}"; then
    echo "Error: Failed to download license-plate-reader.zip"
    rm -rf "$(dirname "${tmp_zip}")"
    exit 1
  fi
  unzip -qo "${tmp_zip}" -d "$(dirname "${tmp_zip}")"
  mkdir -p "${MODELS_DIR}/paddle_ocr_v4"
  cp -r "$(dirname "${tmp_zip}")/license-plate-reader/models/ch_PP-OCRv4_rec_infer"/. "${MODELS_DIR}/paddle_ocr_v4/"
  chmod -R u+rwX "$(dirname "${tmp_zip}")" && rm -rf "$(dirname "${tmp_zip}")"
  if [ ! -f "${MODELS_DIR}/paddle_ocr_v4/ch_PP-OCRv4_rec_infer.xml" ]; then
    echo "Error: Failed to download OCR submodel from license-plate-reader.zip"
    exit 1
  fi
fi
