#!/bin/bash -e

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODEL_PATH="${APP_DIR}/src/dlstreamer-pipeline-server/models/public/yolo11s/INT8/yolo11s.xml"

if [ ! -e "${MODEL_PATH}" ]; then
    echo
    echo "The Smart Parking sample uses the YOLOv11s model for object detection."
    echo "This model is provided by Ultralytics and is subject to its license:"
    echo "  https://github.com/ultralytics/ultralytics/blob/main/LICENSE"
    echo "Disclaimer: by downloading and using this model, you confirm that you accept the"
    echo "license terms and agree to comply with any applicable model-use and privacy requirements."
    while true; do
        read -r -p "Proceed with the YOLOv11s model download and usage? [y/N]: " answer
        case "${answer:-N}" in
            [Yy]|[Yy][Ee][Ss])
                echo "Continuing with the YOLOv11s model download..."
                break
                ;;
            *)
                echo "YOLOv11s model download cancelled. Exiting install.sh."
                exit 1
                ;;
        esac
    done
fi

docker run --rm --user=root \
  -e http_proxy -e https_proxy -e no_proxy \
  -e YOLOV11S_DOWNLOAD_CONFIRMED=1 \
  -v "${APP_DIR}:/opt/project" \
   intel/dlstreamer:2026.2.0-ubuntu24 bash -c "$(cat <<EOF

cd /opt/project
export HOST_IP="${1:-$(hostname -I | cut -f1 -d' ')}"
echo "Configuring application to use \$HOST_IP"

# shellcheck disable=SC1091
. ./update_dashboard.sh \$HOST_IP

##############################################################################
# 4. Process YOLO model (if any)
##############################################################################
mkdir -p src/dlstreamer-pipeline-server/models/public

export MODELS_PATH=/opt/project/src/dlstreamer-pipeline-server/models
chmod +x /home/dlstreamer/dlstreamer/samples/download_public_models.sh
if [ ! -e "src/dlstreamer-pipeline-server/models/public/yolo11s/INT8/yolo11s.xml" ]; then
    if [ "${YOLOV11S_DOWNLOAD_CONFIRMED:-0}" != "1" ]; then
        echo "YOLOv11s model download requires explicit confirmation."
        exit 1
    fi

    for attempt in {1..3}; do
        echo "Attempt $attempt: Running model download and quantization..."
        if /home/dlstreamer/dlstreamer/samples/download_public_models.sh yolo11s coco128; then
            echo "Model download and quantization successful!"
            break
        else
            echo "Download attempt $attempt failed. Retrying..."
            sleep 2
        fi
    done
fi

##############################################################################
# Download and setup videos
##############################################################################
mkdir -p src/dlstreamer-pipeline-server/videos
declare -A video_urls=(
    ["new_video_1.mp4"]="https://github.com/open-edge-platform/edge-ai-resources/raw/0d39322d6c6c578413cdf2a3d48c4e0978531e10/videos/smart_parking_720p_30fps.mp4"
    ["new_video_2.mp4"]="https://github.com/open-edge-platform/edge-ai-resources/raw/0d39322d6c6c578413cdf2a3d48c4e0978531e10/videos/smart_parking_720p_30fps.mp4"
    ["new_video_3.mp4"]="https://github.com/open-edge-platform/edge-ai-resources/raw/0d39322d6c6c578413cdf2a3d48c4e0978531e10/videos/smart_parking_720p_30fps.mp4"
    ["new_video_4.mp4"]="https://github.com/open-edge-platform/edge-ai-resources/raw/0d39322d6c6c578413cdf2a3d48c4e0978531e10/videos/smart_parking_720p_30fps.mp4"
)
for video_name in "\${!video_urls[@]}"; do
    if [ ! -f src/dlstreamer-pipeline-server/videos/\${video_name} ]; then
        echo "Download \${video_name}..."
        curl -L -o "src/dlstreamer-pipeline-server/videos/\${video_name}" "\${video_urls[\$video_name]}" 
    fi
done

echo "Fix ownership..."
chown -R "$(id -u):$(id -g)" src/dlstreamer-pipeline-server/models src/dlstreamer-pipeline-server/videos 2>/dev/null || true

mkdir -p src/nginx/ssl
cd src/nginx/ssl
if [ ! -f server.key ] || [ ! -f server.crt ]; then
    echo "Generate self-signed certificate..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout server.key -out server.crt -subj "/C=US/ST=CA/L=San Francisco/O=Intel/OU=Edge AI/CN=localhost"
    chown -R "$(id -u):$(id -g)" server.key server.crt 2>/dev/null || true

fi

EOF

)"