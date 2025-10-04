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

1. Turn on the Jeton Nano
2. Connect to `msoe-desktop` Wi-Fi
3. Run this command to check if you have an SSH key made:
    ```
    dir C:\Users\%USERNAME%\.ssh
    ```
6. If you don't see a file ending in `.pub`, run this command and don't forget to replace with your email, otherwise, skip to the next step
    ```
    ssh-keygen -t id_ed25519 -C "your_email@example.com"
    ```
7. Run this command (change the path to the SSH key if needed), enter the password for the Jetson Nano user, then type `exit` to close the connection
   ```
   scp C:\Users\%USERNAME%\.ssh\id_ed25519.pub msoe@msoe-desktop:~/.ssh/authorized_keys
   ```
8. Edit `C:\Users\%USERNAME%\.ssh\config` You can open it in VSCode with this command:
   ```
   code C:\Users\%USERNAME%\.ssh\config
   ```
10. Add this to the file:
    ```
    Host msoe-desktop
      HostName msoe-desktop
      User msoe
    ```
11. Save the file
12. In a new command prompt, run this command
    ```
    ssh msoe-desktop
    ```
13. Check that you see this:
    ```
    msoe@msoe-desktop:~$ 
    ```
14. If you do, congrats! You're all set to run commands on the Jetson Nano from your device!
