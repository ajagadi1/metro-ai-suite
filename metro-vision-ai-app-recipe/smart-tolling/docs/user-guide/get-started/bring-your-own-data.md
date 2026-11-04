# Bring Your Own Data

This app ships without sample videos or scene data. Before you run `install.sh`, prepare the
items below.

## What You Need

- **Video files** for the 6 camera views (or live RTSP cameras).
- **A Scenescape scene bundle** (`.tar.bz2`) - your own 3D map with cameras and toll-lane
  regions already placed on it.
- The resolution and layout of your cameras, so you can adjust detection regions to match.

## 1. Add Your Videos

Place your video files in `src/dlstreamer-pipeline-server/videos/` using these exact names:

| File name | Camera view |
| :--- | :--- |
| `FrontView_L_30fps.ts` | Front camera, left lane |
| `FrontView_R_30fps.ts` | Front camera, right lane |
| `RearView_L_30fps.ts` | Rear camera, left lane |
| `RearView_R_30fps.ts` | Rear camera, right lane |
| `SideAxle_Lane_1_30fps.ts` | Side profile, lane 1 |
| `SideAxle_Lane_2_30fps.ts` | Side profile, lane 2 |

Videos must be MPEG-TS (`.ts`) files. If you use different file names, a different number of
cameras, or live RTSP streams instead of files, update the matching pipeline's source in
`src/dlstreamer-pipeline-server/config.json` - see [Perception Layer](../how-it-works/perception-layer.md).

## 2. Add Your Scene

The app needs a Scenescape "scene": a 3D map with cameras and toll-lane regions calibrated on
it, exported as a `.tar.bz2` bundle.

- Build and calibrate your scene using Scenescape's
  [Create a New Scene](https://docs.openedgeplatform.intel.com/dev/scenescape/how-to-guides/build-a-scene/create-new-scene.html)
  and [Integrate Cameras and Sensors](https://docs.openedgeplatform.intel.com/dev/scenescape/how-to-guides/integrate-cameras-and-sensors.html)
  guides.
- Export the created scene to `src/webserver/scenes/smart-tolling/smart-tolling.zip`, keeping this exact name so
  no further changes are needed. To use a different name, see the next step instead.

## 3. Update docker-compose.yml

<TO BE  UPDATED>
If you kept the file name `smart-tolling.tar.bz2`, skip this step. If you used a different
name, edit the `web` service in `compose-smart-tolling-overlay.yml` (the `EXAMPLEDB` value and
its matching volume mount) to point to your file, then regenerate the compose file:

```bash
./install.sh smart-tolling
```

## 4. Update the Pipeline

Camera IDs and detection regions in `config.json` are calibrated for the sample scene. After
swapping in your own videos and scene, update for each pipeline in
[Perception Layer](../how-it-works/perception-layer.md):

- The camera ID, to match the cameras defined in your new scene.
- The detection region (`gvaattachroi`), to match your video resolution and camera framing.

## Learn More

- [Get Started](../get-started.md)
- [Perception Layer](../how-it-works/perception-layer.md)
- [Scenescape Documentation](https://docs.openedgeplatform.intel.com/dev/scenescape/index.html)
