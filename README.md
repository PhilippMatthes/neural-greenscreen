# Neural Greenscreen

Based on [seanchas116/SimpleDALPlugin](https://github.com/seanchas116/SimpleDALPlugin) and [johnboiles/coremediaio-dal-minimal-example](https://github.com/johnboiles/coremediaio-dal-minimal-example).

![Demo](demo.png)

## How to run
- Build Neural Greenscreen in Xcode
- Copy neuralGreenscreenMain.plugin into /Library/CoreMediaIO/Plug-Ins/DAL
- `cd` into the root directory of this repository
- `yarn` to install all dependencies
- `yarn start` to start the tensorflow js server on port 9000
- Open Webcam-using app and choose Neural Greenscreen as camera input

## What else?

* [Cameo](https://github.com/lvsti/Cameo) is good for debugging!
