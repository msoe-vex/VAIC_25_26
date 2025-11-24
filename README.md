# The VEX AI Competition (VAIC) System

## [JetsonExample](./JetsonExample/README.md)

JetsonExample contains the default code that powers the VEX AI system, from processing image data and running the AI model to detect objects for the VEX V5 Brain.

## [JetsonImages](./JetsonImages/README.md)

JetsonImages is where you will find how to get the most up-to-date image of the NVIDIA Jetson Nano and Raspberry Pi 5 and instructions on how to install the SD card image and or building from source.

## [JetsonWebDashboard](./JetsonWebDashboard/README.md)

JetsonWebDashboard is where you will find the source code for the VEX AI Web Dashboard that runs on the Jetson Nano/Raspberry Pi.

## [V5Example](./V5Example/ai_demo/README.md)

V5Example contains the `ai_demo` V5 Project which has examples on how to connect with the Jetson Nano/Raspberry Pi and how to interpret and process the data from the board on the V5 Brain

## Connecting to the Jetson Nano via Bluetooth PAN

1. Turn on the Jetson Nano, wait a few minutes for it to boot up and start the bluetooth service
2. On Windows 11, open Settings > Bluetooth & devices > Devices > View more devices
3. Under "Device Settings," set "Bluetooth devices discovery" to "Advanced"
4. Click "Add device" and select "Bluetooth" then select `msoe-nano1` from the list
5. Once connected, find `msoe-nano1` in the list of devices, click the three dots next to it, and select "Join Person Area Network (PAN)"
6. Select "Access Point" from the dropdown and click "Connect"

## SSH Access on Jetson Orin Nano

1. Connect to the Jetson Nano through the Bluetooth PAN as described above
3. Next, edit `C:\Users\%USERNAME%\.ssh\config` You can open it in VSCode with this command:
    ```
    code C:\Users\%USERNAME%\.ssh\config
    ```
4. Add this to the file:
    ```
    Host msoe-nano*
        HostName msoe-nano
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

## Connecting to the VEX AI Web Dashboard

1. Connect to the Jetson Nano through the Bluetooth PAN as described above
2. Open a web browser and navigate to `http://msoe-nano1:3000/#/`