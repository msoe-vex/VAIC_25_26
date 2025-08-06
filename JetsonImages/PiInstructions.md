## Build the VEX AI System from Source for Raspberry Pi 5
Go to https://www.raspberrypi.com/software/ and download the Raspberry Pi Imager and flash your SD card with Raspberry Pi OS (64 bit). It is recommended to create your own login and input your network credentials. Optionally, you can enable SSH if you want to use your Pi headless. Then follow the instructions below to initalize the VEX AI System.

Set-up Raspberry Pi OS on the Pi and open a terminal (Ctrl + Alt + T)

**Ensure your Pi is connected to the Internet via Ethernet or Wi-Fi**

*Hint: You can copy and paste in the terminal with (Ctrl + Shift + V)*

---
**This will update and upgrade the packages that come default with the Pi**

1: `sudo apt-get update && sudo apt-get -y upgrade`

**We need to setup the Python environment for our project**

Raspberry Pi OS currently ships with Python 3.11, however the PyCoral library only supports up to Python 3.9.
We will use a tool called pyenv to setup our environment without replacing the system-wide Python version

**Pyenv will require compiling Python from source, so the build dependencies must be installed**

2: `sudo apt-get install -y make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev wget curl llvm libncurses5-dev libncursesw5-dev xz-utils tk-dev libffi-dev liblzma-dev`

**Pyenv can now be installed**

3: `curl https://pyenv.run | bash`

4: 
```
echo 'export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash)"' >> ~/.bashrc
```
Then close and reopen your terminal or run `source ~/.bashrc` 

**Install Python 3.9.22. Note: this command will take some time as it will compile Python from source**

5: `pyenv install 3.9.22 && pyenv global 3.9.22`:

**Then we want to install git and clone the 'librealsense' library from Intel**

6: `sudo apt-get install git`

*`sudo apt autoremove (optional)`*

7: `git clone https://github.com/IntelRealSense/librealsense.git`

**Now you should have a folder in your home directory named 'librealsense'**

**Navigate into the directory (cd librealsense) and run the following**

**Make sure you have all RealSense cameras unplugged**

8: `sudo apt-get install -y git libssl-dev libusb-1.0-0-dev pkg-config libgtk-3-dev`

9: `sudo apt-get install libglfw3-dev libgl1-mesa-dev libglu1-mesa-dev at cmake`

10: `./scripts/setup_udev_rules.sh`

11: `mkdir build && cd build`

**Build the files**

12: `cmake ../ -DFORCE_RSUSB_BACKEND=ON -DBUILD_PYTHON_BINDINGS:bool=true -DPYTHON_EXECUTABLE=$(which python3) -DPYTHON_INSTALL_DIR=$(pyenv prefix)/lib/python3.9/site-packages/pyrealsense2 -DPYTHON_LIBRARY=$(pyenv prefix)/lib/libpython3.9.so -DCMAKE_BUILD_TYPE=release`

**This next one is gonna take a while (like 15-20 min)! The -j4 flag means to use 4 cores in parallel**

13: `sudo make uninstall && sudo make clean && sudo make -j4 && sudo make install`

**For some reason, make install does not always install the pyrealsense2 files as expected. To fix this, run the following command from the build directory**

14: `sudo cp release/pyrealsense2.cpython-39-aarch64-linux-gnu.so* $(pyenv prefix)/lib/python3.9/site-packages/pyrealsense2 && echo "from .pyrealsense2 import *" | sudo tee $(pyenv prefix)/lib/python3.9/site-packages/pyrealsense2/__init__.py`

**Clone the GitHub repository with all of the example source code**

15: `git clone https://github.com/VEX-Robotics/VAIC_25_26.git`

**Navigate into the source directory (`cd VAIC_25_26/JetsonExample`)**

**Install all the required python packages**

16:
```
python -m pip install --upgrade pip
pip install pyserial websocket-server Pillow opencv-python
pip install --extra-index-url https://google-coral.github.io/py-repo/ pycoral~=2.0
pip install "numpy<2.0"
```

**Install Coral Edge TPU Runtime**

17:
```
echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" | sudo tee /etc/apt/sources.list.d/coral-edgetpu.list
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
sudo apt-get update
sudo apt-get install libedgetpu1-std
```

**If using the M.2 PCI-E Coral Accelerator, the driver must be installed. However, the driver does not support the latest kernel version, so a patch must be applied and then it must be compiled and installed. If you are using the USB accelerator, you may skip to step 24**

**Clone the driver repository**

18: `git clone https://github.com/google/gasket-driver.git`

**Enter the driver directory (`cd gasket-driver`)**

**Apply the patch**

19: `git apply ~/VAIC_25_26/JetsonImages/fix_gasket_driver.patch`

**Install development packages needed for driver compilation**

20: `sudo apt-get -y install devscripts build-essential lintian dkms dh-dkms`

**Compile and install the driver**

21: `debuild -us -uc -tc -b && sudo dpkg -i ../gasket-dkms_1.0-18_all.deb`

**In addition to the driver, some boot options must be applied to allow the M.2 accelerator to work on the Raspberry Pi**

22: `echo -e "kernel=kernel8.img\ndtparam=pciex1\ndtparam=pciex1_gen=3\ndtoverlay=pineboards-hat-ai" | sudo tee -a /boot/firmware/config.txt`

23: 
```
    sudo sh -c "echo 'SUBSYSTEM==\"apex\", MODE=\"0660\", GROUP=\"apex\"' >> /etc/udev/rules.d/65-apex.rules"
    sudo groupadd apex
    sudo adduser $USER apex
```

24: `sudo usermod -a <USERNAME> -G dialout`

**BEFORE PROCEEDING, MAKE SURE YOU FOLLOW THE STEPS TO SET-UP THE VEX AI WEB DASHBOARD**

[Install NodeJS and Build the Server](../JetsonWebDashboard/README.md)

**Create the Hotspot network with the following command.**
**This will create a network called "VexAI" with password "vexrobotics".**

**If you would like to change these, change VexAI after ssid or vexrobotics after wifi-sec.psk**

**Note: if you are connected to the internet over WiFi, this command will disconnect you**

**If you are connected over Ethernet, you must run `raspi-config` and go into "Wireless Lan" under System Options and enter your region, then exit**

25: `sudo nmcli c add type wifi ifname wlan0 mode ap con-name Hotspot ssid VexAI ipv4.method shared wifi-sec.key-mgmt wpa-psk wifi-sec.psk "vexrobotics" autoconnect yes && sudo nmcli c up Hotspot`

**Navigate into the Scripts folder within the source directory (`cd ~/VAIC_25_26/JetsonExample/Scripts`)**

**Run the script that will install the vexai service to start object detection for the VEX AI Compeittion upon start up**

26: `sudo chmod +x service.sh`

27: `sudo chmod +x run.sh`

28: `sudo bash ./service.sh`

***The python script running object detection will now run in the background upon start up***

**Reboot your Pi and everything should be running correctly**