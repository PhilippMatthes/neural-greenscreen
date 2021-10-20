# Neural Greenscreen

Realtime background removal with neural networks on mac os, providing a virtual camera, which can be accessed by third party applications.

![Demo](demo.png)

Based on [seanchas116/SimpleDALPlugin](https://github.com/seanchas116/SimpleDALPlugin) and [johnboiles/coremediaio-dal-minimal-example](https://github.com/johnboiles/coremediaio-dal-minimal-example).

# Prerequesites

- A system running mac os with a builtin webcam
- Xcode

# Setup

- Check your webcam dimensions and change the code if your webcam is higher resolution than 1280 x 720 (Automatic detection is in progress)
- Build neural-greenscreen in Xcode
- Copy neuralGreenscreenMain.plugin into `/Library/CoreMediaIO/Plug-Ins/DAL`
- Open app that uses your webcam and choose Neural Greenscreen as camera input

You should see the background being removed.

# Troubleshooting

DAL plugins access very low level mac os interfaces. It could be that the plugin is not detected or crashes depending on your system or app. If you find a problem, report it so that we can fix it. Here is a recommended workflow:

- Check your logs (using the mac os console, search for `neural`)
- Open an issue explaining your problem

# License

This project is licensed under `MIT License`.
