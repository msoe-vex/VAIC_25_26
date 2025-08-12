## Using the VEXAI Jetson Nano or Raspberry Pi image
We have software support for both Nvidia Jetson Nano and Raspberry Pi 5 with Google Coral Edge TPU devices.

Select and download the correct image for your device from below

* [Jetson OS Image](https://content.vexrobotics.com/V5AI/Images/Jetson/VAIC_25_26_JETSON_080625.img.gz)
* [Raspberry Pi OS Image](https://content.vexrobotics.com/V5AI/Images/Jetson/VAIC_25_26_RPI_080625.img.gz)
  
> [!WARNING]
> Please note that the Raspberry Pi image was built specifically for the Pi 5 with a Google Coral Edge TPU device installed or plugged in and may not work or perform as expected on other Pi models.

You will need the following prerequisites:

1. Download, install, and launch [Etcher](https://www.balena.io/etcher). 
2. A formatted SD-card that is at **least 32GB**.

In Etcher, select the image you downloaded as the image to flash. Pick the correct target to flash to and then Flash using Etcher.

You should now be able to slot your SD card into your NVIDIA Jetson Nano or Raspberry Pi and it will start running the VEX AI system.

The password to either device (should you need to bring up the display and change anything) is `password`.