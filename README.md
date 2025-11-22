# The VEX AI Competition (VAIC) System

## [JetsonExample](./JetsonExample/README.md)

JetsonExample contains the default code that powers the VEX AI system, from processing image data and running the AI model to detect objects for the VEX V5 Brain.

## [JetsonImages](./JetsonImages/README.md)

JetsonImages is where you will find how to get the most up-to-date image of the NVIDIA Jetson Nano and Raspberry Pi 5 and instructions on how to install the SD card image and or building from source.

## [JetsonWebDashboard](./JetsonWebDashboard/README.md)

JetsonWebDashboard is where you will find the source code for the VEX AI Web Dashboard that runs on the Jetson Nano/Raspberry Pi.

## [V5Example](./V5Example/ai_demo/README.md)

V5Example contains the `ai_demo` V5 Project which has examples on how to connect with the Jetson Nano/Raspberry Pi and how to interpret and process the data from the board on the V5 Brain

## SSH Access on Jetson Orin Nano

1. Turn on the Jeton Nano, wait a few minutes for it to boot up and start the bluetooth service
2. Connect to `msoe-nano1` via bluetooth
    - On Windows 11, open Settings > Bluetooth & devices > Devices > View more devices
    - Under "Device Settings," set "Bluetooth devices discovery" to "Advanced"
    - Click "Add device" and select "Bluetooth" then select `msoe-nano1` from the list
    - Once connected, find `msoe-nano1` in the list of devices, click the three dots next to it, and select "Join Person Area Network (PAN)"
    - Select "Access Point" from the dropdown and click "Connect"
3. Next, edit `C:\Users\%USERNAME%\.ssh\config` You can open it in VSCode with this command:
    ```
    code C:\Users\%USERNAME%\.ssh\config
    ```
4. Add this to the file:
    ```
    Host msoe-nano1
        HostName 192.168.100.1
        User msoe
    ```
5. Save the file
6. After updating your SSH config file, run this command to check if you have an SSH key made:
    ```
    dir C:\Users\%USERNAME%\.ssh
    ```
7. If you see a file ending in `.pub`, skip this step. Otherwise, run this command and don't forget to replace with your email. Type enter to accept the default options for file location and to leave the passphrase blank.
    ```
    ssh-keygen -t ed25519 -C "your_email@example.com"
    ```
8. Run this command (change the path to the SSH key if needed), enter the password for the Jetson Nano user, then type `exit` to close the connection
    ```
    type C:\Users\%USERNAME%\.ssh\id_ed25519.pub | ssh msoe-nano1 "cat >> ~/.ssh/authorized_keys"
    ```
9. In a new command prompt, run this command
    ```
    ssh msoe-nano1
    ```
10. Check that you see this:
    ```
    msoe@msoe-nano1:~$ 
    ```
11. If you do, congrats! You're all set to run commands on the Jetson Nano from your device!