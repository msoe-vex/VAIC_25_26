# Import necessary libraries
import pyrealsense2 as rs
import numpy as np
import cv2
import time
import os
import threading
from glob import glob

from V5MapPosition import MapPosition

import V5Comm
from V5Comm import V5SerialComms
from V5Position import Position
from V5Position import V5GPS
from V5Web import V5WebData
from V5Web import Statistics, CameraOffset, GPSOffset

from model import Model, rawDetection

import sys
import os

# Add repository root to path for VEXAIRL imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from VEXAIRL.vex_model_run import VexModelRunner
from VEXAIRL.pushback.vexai_skills import VexAISkillsGame
from VEXAIRL.vex_core.base_game import Robot, Team, RobotSize
from VEXAIRL.vex_core.config import CommunicationOption
from VEXAIRL.pushback.pushback import ObsIndex, SENTINEL_BLOCK_VALUE, Actions


METERS_TO_INCHES = 39.3701
INCHES_TO_METERS = 1 / METERS_TO_INCHES

class Camera:
    # Class handles Camera object instantiation and data requests.
    def __init__(self):
        self.pipeline = rs.pipeline()  # Initialize RealSense pipeline
        self.config = rs.config()
        # Enable depth stream at 640x480 in z16 encoding at 30fps
        self.config.enable_stream(rs.stream.depth, 640, 480, rs.format.z16, 30)
        # Enable color stream at 640x480 in rgb8 encoding at 30fps
        self.config.enable_stream(rs.stream.color, 640, 480, rs.format.rgb8, 30)

    def start(self):
        self.profile = self.pipeline.start(self.config)  # Start the pipeline
        # Obtain depth sensor and calculate depth scale
        depth_sensor = self.profile.get_device().first_depth_sensor()
        self.depth_scale = depth_sensor.get_depth_scale()
        self.profile.get_device().query_sensors()[1].set_option(rs.option.auto_exposure_priority, 0.0)

    def get_frames(self):
        return self.pipeline.wait_for_frames()  # Wait and fetch frames from the pipeline

    def stop(self):
        self.pipeline.stop()  # Stop the pipeline when finished


class Processing:
    # Class to handle camera data processing, preparing for inference, and running inference on camera image.
    def __init__(self, depth_scale, profile):
        self.depth_scale = depth_scale
        self.align_to = rs.stream.color
        self.align = rs.align(self.align_to)  # Align depth frames to color stream
        self.model = Model()  # Initialize the object detection model
        self.HUE = 0
        self.SATURATION = 0
        self.VALUE = 0
        self.depth_intrin = profile.get_stream(rs.stream.depth).as_video_stream_profile().get_intrinsics()
        self.color_intrin = profile.get_stream(rs.stream.color).as_video_stream_profile().get_intrinsics()
        self.depth_to_color_extrin =  profile.get_stream(rs.stream.depth).as_video_stream_profile().get_extrinsics_to( profile.get_stream(rs.stream.color))
        self.color_to_depth_extrin =  profile.get_stream(rs.stream.color).as_video_stream_profile().get_extrinsics_to( profile.get_stream(rs.stream.depth))

    def process_image(self, image):
        # Enhances the image by shifting the hue and adjusting saturation and brightness.

        if (self.HUE == 0 and self.SATURATION == 0 and self.VALUE == 0):
            return image

        # Convert the image to HSV color space
        hsv = cv2.cvtColor(image, cv2.COLOR_RGB2HSV)

        # Modify the hue, saturation, and value channels
        hsv[..., 0] = hsv[..., 0] + self.HUE
        hsv[:, :, 1] = np.clip(hsv[:, :, 1] * self.SATURATION, 0, 255)
        hsv[:, :, 2] = np.clip(hsv[:, :, 2] * self.VALUE, 0, 255)

        # Convert the image back to RGB color space for inferencing
        return cv2.cvtColor(hsv, cv2.COLOR_HSV2RGB)

    def updateHSV(self, newHSV):
        self.HUE = newHSV.h

        if (self.SATURATION >= 0):
            self.SATURATION = 1 + (newHSV.s) / 100
        else:
            self.SATURATION = (100 - abs(newHSV.s)) / 100

        if (self.VALUE >= 0):
            self.VALUE = 1 + (newHSV.v) / 100
        else:
            self.VALUE = (100 - abs(newHSV.v)) / 100

    def project_color_to_depth(self, depth_data, pixel):
        row, col = pixel
        depth_pixel = tuple(map(int, rs.rs2_project_color_pixel_to_depth_pixel(depth_data, 
                            self.depth_scale, 0.05, 3, self.depth_intrin, self.color_intrin, self.color_to_depth_extrin, 
                            self.depth_to_color_extrin, [row, col])))
        return depth_pixel

    def get_depth(self, detection: rawDetection, depth_img):
        # Compute the bounding box indices for the detection
        height = detection.Height
        width = detection.Width

        # Calculate the indices of 50% of the detection (center crop)
        # using 25% margin on each side (25-75 range)
        low_limit_y = 25
        high_limit_y = 75
        low_limit_x = 25
        high_limit_x = 75
        
        top = int(detection.y) + height * low_limit_y // 100
        bottom = int(detection.y) + height * high_limit_y // 100
        left = int(detection.x) + width * low_limit_x // 100
        right = int(detection.x) + width * high_limit_x // 100

        # Ensure indices are within bounds
        top = max(0, top)
        left = max(0, left)
        bottom = min(depth_img.shape[0], bottom)
        right = min(depth_img.shape[1], right)

        # Slice depth image directly (frames are aligned)
        depth_slice = depth_img[top:bottom, left:right]
        
        # Apply depth scale
        depth_slice = depth_slice * self.depth_scale
        
        # Filter non-zero depth values
        valid_depths = depth_slice[depth_slice != 0]

        if valid_depths.size == 0:
            return -1

        # Compute mean depth value
        meanDepth = np.nanmean(valid_depths)
        
        if np.isnan(meanDepth):
            return -1
            
        return meanDepth

    def align_frames(self, frames):
        # Align depth frames to color frames
        aligned_frames = self.align.process(frames)
        # Get the aligned frames and validate them
        self.depth_frame_aligned = aligned_frames.get_depth_frame()
        self.color_frame_aligned = aligned_frames.get_color_frame()

        if not self.depth_frame_aligned or not self.color_frame_aligned:
            print(f"WARNING: Invalid frames - depth: {self.depth_frame_aligned is not None}, color: {self.color_frame_aligned is not None}")
            self.depth_frame_aligned = None
            self.color_frame_aligned = None

    def process_frames(self, frames):
        # Align frames and extract color and depth images
        # Apply a color map to the depth image
        self.align_frames(frames)
        if self.depth_frame_aligned is None or self.color_frame_aligned is None:
            return None, None, None
        depth_image = np.asanyarray(self.depth_frame_aligned.get_data())
        color_image = np.asanyarray(self.color_frame_aligned.get_data())
        # apply color correction to image
        color_image = self.process_image(color_image)
        depthImage = cv2.normalize(depth_image, None, alpha=0.01, beta=255, norm_type=cv2.NORM_MINMAX, dtype=cv2.CV_8U)
        depth_map = cv2.applyColorMap(depthImage, cv2.COLORMAP_JET)

        return depth_image, color_image, depth_map

    def detect_objects(self, color_image):
        # Perform object detection and return results using the Model class in model.py
        output, detections = self.model.inference(color_image)
        return output, detections

    def compute_detections(self, v5, detections, depth_image):
        # Create AIRecord and compute detections with depth and image data.
        # Each AIRecord contains the ClassID, Probablity, and depth information for each detection
        # In addition to the detection's camera image and map position information.
        aiRecord = V5Comm.AIRecord(v5.get_v5Pos(), [])
        for detection in detections:
            depth = self.get_depth(detection, depth_image)
            imageDet = V5Comm.ImageDetection(
                int(detection.x),
                int(detection.y),
                int(detection.Width),
                int(detection.Height),
            )
            mapPos = v5.v5Map.computeMapLocation(detection, depth, aiRecord.position)
            mapDet = V5Comm.MapDetection(mapPos[0], mapPos[1], mapPos[2])
            detect = V5Comm.Detection(
                int(detection.ClassID),
                float(detection.Prob),
                float(depth),
                imageDet,
                mapDet,
            )
            aiRecord.detections.append(detect)
        return aiRecord


class Rendering:
    # Class to handle rendering camera data and process stat data to the webserver.
    def __init__(self, web_data):
        self.web_data = web_data
        self.cpu_temp_path = "/sys/devices/virtual/thermal/thermal_zone0/temp"

        # loop through available thermal zones to see if any are labeled CPU
        for thermal_zone in glob("/sys/devices/virtual/thermal/thermal_zone*"):
            zone_type = os.popen(f"cat {thermal_zone}/type").read().rstrip("\n")
            # if labeled CPU, use that zone instead
            if "cpu" in zone_type.lower():
                self.cpu_temp_path = thermal_zone + "/temp"

    def set_images(self, output, depth_image):
        # Update web data with color and depth images
        self.web_data.setColorImage(output)
        self.web_data.setDepthImage(depth_image)

    def set_detection_data(self, aiRecord):
        # Update web data with detection information
        self.web_data.setDetectionData(aiRecord)
    
    def set_stats(self, stats, v5Pos, start_time, invoke_time, run_time):
        # Set the statistics for FPS, invoke time, run time, and CPU temp
        stats.fps = 1.0 / (time.time() - start_time)
        stats.gpsConnected = v5Pos.isConnected()
        stats.invokeTime = invoke_time
        stats.runTime = time.time() - run_time
        with open(self.cpu_temp_path, "r") as f:
            temp_str = f.readline().rstrip("\n")
        temp = float(temp_str) / 1000
        stats.cpuTemp = temp
        self.web_data.setStatistics(stats)

    def display_output(self, output):
        # Display the output image in a window
        # Handle window closing with 'q' or 'esc' keys
        cv2.namedWindow("VEX HighStakes", cv2.WINDOW_AUTOSIZE)
        cv2.imshow("VEX HighStakes", output)
        key = cv2.waitKey(1)
        if key & 0xFF == ord("q") or key == 27:
            cv2.destroyAllWindows()



class PushbackHandler:
    """
    Callback handler for V5Comm to manage VEXAIRL observations and model inference.
    """
    
    # Block class IDs from detection model
    # labels.txt is ordered: BallBlue (0), BallRed (1)
    CLASS_RED_BLOCK = 1
    CLASS_BLUE_BLOCK = 0
    
    MAX_TRACKED_BLOCKS = 15
    ACK_TIMEOUT_SEC = 0.25
    RESEND_POLL_SEC = 0.02
    
    def __init__(self, write_func, update_camera_func, update_gps_func, v5gps):
        self._model_runner: VexModelRunner = None
        self._observation = np.zeros(ObsIndex.TOTAL, dtype=np.float32)
        self._write = write_func
        self._team: Team = None  # Set when model is initialized
        self._start_time: float = None
        self._total_time: float = None
        self._update_camera = update_camera_func
        self._update_gps = update_gps_func
        self._last_message: np.ndarray = None  # Latest message vector from model
        self._x = None
        self._y = None
        self._orient = None
        self.v5gps = v5gps
        self._action_sequence = 0
        self._pending_action_seq = None
        self._pending_action_body = None
        self._pending_action_sent_at = None
        self._pending_action_retries = 0
        self._pending_lock = threading.Lock()
        self._ack_watchdog_thread = threading.Thread(target=self._ack_watchdog_loop, daemon=True)
        self._ack_watchdog_thread.start()
                
    def set_write_func(self, write_func):
        """Set the write callback after construction."""
        self._write = write_func
        
    @property
    def observation(self):
        return self._observation
    
    @property
    def model_runner(self):
        return self._model_runner

    def _clear_pending_action(self):
        with self._pending_lock:
            self._pending_action_seq = None
            self._pending_action_body = None
            self._pending_action_sent_at = None
            self._pending_action_retries = 0

    def _set_pending_action(self, seq: int, body: str):
        with self._pending_lock:
            self._pending_action_seq = seq
            self._pending_action_body = body
            self._pending_action_sent_at = time.time()
            self._pending_action_retries = 0

    def _acknowledge_action_seq(self, ack_body: str):
        try:
            ack_seq = int(ack_body.strip())
        except Exception:
            print(f"[WARNING] Invalid ACK payload: '{ack_body}'", flush=True)
            return

        with self._pending_lock:
            if self._pending_action_seq is None:
                print(f"[DEBUG] ACK {ack_seq} received with no pending action", flush=True)
                return

            if ack_seq == self._pending_action_seq:
                self._pending_action_seq = None
                self._pending_action_body = None
                self._pending_action_sent_at = None
                self._pending_action_retries = 0
                print(f"[DEBUG] ACK received for action seq {ack_seq}", flush=True)
            elif ack_seq < self._pending_action_seq:
                print(f"[DEBUG] Ignoring stale ACK seq {ack_seq}; waiting for {self._pending_action_seq}", flush=True)
            else:
                print(f"[DEBUG] ACK seq {ack_seq} ahead of pending seq {self._pending_action_seq}; clearing pending", flush=True)
                self._pending_action_seq = None
                self._pending_action_body = None
                self._pending_action_sent_at = None
                self._pending_action_retries = 0

    def _ack_watchdog_loop(self):
        while True:
            time.sleep(self.RESEND_POLL_SEC)

            resend_seq = None
            resend_body = None
            resend_retry = None

            with self._pending_lock:
                if (
                    self._pending_action_seq is not None
                    and self._pending_action_body is not None
                    and self._pending_action_sent_at is not None
                    and (time.time() - self._pending_action_sent_at) >= self.ACK_TIMEOUT_SEC
                ):
                    resend_seq = self._pending_action_seq
                    resend_body = self._pending_action_body
                    self._pending_action_retries += 1
                    resend_retry = self._pending_action_retries
                    self._pending_action_sent_at = time.time()

            if resend_seq is not None and self._write is not None:
                self._write("RUN_ACTION", resend_body)
                timeout_ms = int(self.ACK_TIMEOUT_SEC * 1000)
                print(f"[WARNING] No ACK for seq {resend_seq} after {timeout_ms}ms; resend #{resend_retry}", flush=True)

    def _send_action(self):
        """
        Send next action to robot after computing inference from observation.
        
        This method:
        1. Validates that model runner is initialized
        2. Updates time remaining in observation
        3. Calls model inference pipeline (observation -> action)
        4. Validates action before sending
        5. Sends action and split commands to robot
        """
        if self._model_runner is None or self._write is None:
            print("[ERROR] Model runner or write function not initialized, cannot send action.", flush=True)
            return

        # Update time remaining
        if self._start_time is not None and self._total_time is not None:
            self._observation[ObsIndex.TIME_REMAINING] = max(self._total_time - (time.time() - self._start_time), 0)

        try:
            # Get action from model inference pipeline
            # This includes update_observation_from_tracker() which fills tracker fields
            action, split_actions, message_vector = self._model_runner.get_inference(self._observation)
            self._last_message = message_vector
            
            # Validation
            if action is None:
                print("[ERROR] Model returned None action", flush=True)
                return
            
            if not split_actions or len(split_actions) == 0:
                print("[WARNING] Model returned empty split_actions, using default idle", flush=True)
                split_actions = ["IDLE"]
            
            # Send action to robot with sequence prefix: seq/action/sub1/sub2/...
            seq = self._action_sequence
            send_body = str(seq) + "/" + str(action) + "/" + "/".join(split_actions)
            self._write("RUN_ACTION", send_body)
            self._set_pending_action(seq, send_body)
            self._action_sequence += 1
            try:
                action_name = Actions(action).name
            except (ValueError, KeyError):
                action_name = str(action)

            print(f"[INFO] Sent action seq {seq} ({action_name}) with {len(split_actions)} commands", flush=True)
            
        except Exception as e:
            print(f"[ERROR] Action inference failed: {str(e)}", flush=True)
            # Send fallback IDLE action
            try:
                seq = self._action_sequence
                fallback_body = str(seq) + f"/{Actions.IDLE.value}/{Actions.IDLE.name}"  # Actions.IDLE = 13
                self._write("RUN_ACTION", fallback_body)
                self._set_pending_action(seq, fallback_body)
                self._action_sequence += 1
                print("[INFO] Sent fallback IDLE action due to inference error", flush=True)
            except Exception as e2:
                print(f"[CRITICAL] Failed to send fallback action: {str(e2)}", flush=True)
    
    def handle(self, rec_header: str, rec_body: str) -> None:
        """Handle incoming USB message from V5Comm."""
        rec_header_upper = rec_header.upper()

        if (rec_header_upper not in ['VL','VR','LV','RV','LT','RT', 'POS', '']):
            print(f"[DEBUG] Received message - Header: '{rec_header}', Body: '{rec_body}'", flush=True)
        
        if rec_header_upper == "INIT":
            parts = rec_body.split(',')
            if len(parts) < 17:
                raise ValueError("Expected 17 comma-separated values: name, team, size, length, width, start_x, start_y, start_orient, cam_x, cam_y, cam_z, cam_heading, cam_elevation, gps_x, gps_y, gps_z, gps_heading")
            name = parts[0].strip()
            print(f"[DEBUG] Initializing model for robot '{name}'", flush=True)
            team = Team(parts[1].strip().lower())
            print(f"[DEBUG] Team set to '{team.name}'", flush=True)
            size = RobotSize(int(parts[2].strip()))
            print(f"[DEBUG] Robot size set to '{size.name}'", flush=True)
            length = float(parts[3].strip())
            print(f"[DEBUG] Robot length set to '{length}'", flush=True)
            width = float(parts[4].strip())
            print(f"[DEBUG] Robot width set to '{width}'", flush=True)
            start_x = float(parts[5].strip())
            print(f"[DEBUG] Robot start_x set to '{start_x}'", flush=True)
            start_y = float(parts[6].strip())
            print(f"[DEBUG] Robot start_y set to '{start_y}'", flush=True)
            start_orient = float(parts[7].strip())
            print(f"[DEBUG] Robot start_orientation set to '{start_orient}'", flush=True)
            cam_x = float(parts[8].strip())*INCHES_TO_METERS
            print(f"[DEBUG] Camera offset x set to '{cam_x}' meters", flush=True)
            cam_y = float(parts[9].strip())*INCHES_TO_METERS
            print(f"[DEBUG] Camera offset y set to '{cam_y}' meters", flush=True)
            cam_z = float(parts[10].strip())*INCHES_TO_METERS
            print(f"[DEBUG] Camera offset z set to '{cam_z}' meters", flush=True)
            cam_heading = float(parts[11].strip())
            print(f"[DEBUG] Camera heading offset set to '{cam_heading}' degrees", flush=True)
            cam_elevation = float(parts[12].strip())
            print(f"[DEBUG] Camera elevation offset set to '{cam_elevation}' degrees", flush=True)
            gps_x = float(parts[13].strip())*INCHES_TO_METERS
            print(f"[DEBUG] GPS offset x set to '{gps_x}' meters", flush=True)
            gps_y = float(parts[14].strip())*INCHES_TO_METERS
            print(f"[DEBUG] GPS offset y set to '{gps_y}' meters", flush=True)
            gps_z = float(parts[15].strip())*INCHES_TO_METERS
            print(f"[DEBUG] GPS offset z set to '{gps_z}' meters", flush=True)
            gps_heading = float(parts[16].strip())
            print(f"[DEBUG] GPS heading offset set to '{gps_heading}' degrees", flush=True)

            self._update_camera(CameraOffset(cam_x, cam_y, cam_z, "meters", cam_heading, cam_elevation))
            self._update_gps(GPSOffset(gps_x, gps_y, gps_z, "meters", gps_heading))

            self.v5gps.updatePositionOverride(start_x, start_y, start_orient)  # Set initial position in V5GPS

            self._team = team  # Store team for block classification

            robot = Robot(
                name=name,
                team=team,
                size=size,
                length=length,
                width=width,
                start_position=np.array([start_x, start_y], dtype=np.float32),
                start_orientation=start_orient
            )
            game = VexAISkillsGame(
                robots=[robot],
                communication_mode=CommunicationOption.ATTENTION,
                deterministic=False
            )
            
            current_folder_path = os.path.dirname(os.path.abspath(__file__))
            model_path = os.path.join(current_folder_path, "models", name+".pt")
            
            # Initialize VexModelRunner with the game
            self._model_runner = VexModelRunner(
                model_path=model_path,
                game=game,
            )
            
            # Reset observation array
            self._observation = np.zeros(ObsIndex.TOTAL, dtype=np.float32)

            # Reset action sequence
            self._action_sequence = 0
            self._clear_pending_action()
            
            # Verify setup
            if self._model_runner.model is None:
                print(f"[WARNING] Model failed to load from {model_path}", flush=True)
            else:
                print(f"[INFO] VexModelRunner initialized successfully for robot '{name}'", flush=True)
                print(f"[INFO] Agent: {self._model_runner.agent_name}, Device: {self._model_runner.device}", flush=True)
            
        elif rec_header_upper == "ACTION_DONE":
            # Update model state after action completion, then run inference
            # Treat ACTION_DONE as implicit delivery confirmation to avoid unnecessary resends.
            self._clear_pending_action()
            if rec_body and self._model_runner:
                try:
                    action = int(rec_body)
                    self._model_runner.run_action(action)
                except Exception as e:
                    print(f"[WARNING] Failed to apply ACTION_DONE payload '{rec_body}': {e}", flush=True)
            self._send_action()
            
        elif rec_header_upper == "START":
            print("[DEBUG] Received START command", flush=True)
            self._action_sequence = 0
            self._clear_pending_action()
            self._start_time = time.time()
            self._total_time = float(rec_body)
            self._send_action()

        elif rec_header_upper == "ACK":
            self._acknowledge_action_seq(rec_body)
            
        elif rec_header_upper == "POS":
            # Update self position
            try:
                parts = [p.strip() for p in rec_body.split(',')]
                if len(parts) >= 3:
                    self._observation[ObsIndex.SELF_POS_X] = float(parts[0])
                    self._observation[ObsIndex.SELF_POS_Y] = float(parts[1])
                    self._observation[ObsIndex.SELF_ORIENT] = float(parts[2])
                    self._x = float(parts[0])
                    self._y = float(parts[1])  
                    self._orient = float(parts[2])

                    # Update V5GPS state through its public API (avoids name-mangling private attrs).
                    self.v5gps.updatePositionOverride(self._x, self._y, self._orient)
            except Exception as e:
                print(f"Failed to parse pos payload '{rec_body}': {e}")
            
        elif rec_header_upper == "MESSAGE":
            # Update received message in observation from teammate
            try:
                parts = [float(p.strip()) for p in rec_body.split(',')]
                for i in range(min(len(parts), 8)):
                    self._observation[ObsIndex.RECEIVED_MSG_START + i] = parts[i]
            except Exception as e:
                print(f"Failed to parse MESSAGE payload '{rec_body}': {e}")
    
    def handle_detections(self, detections: list) -> None:
        """
        Handle detections callback from camera processing.
        Updates block positions in the observation.
        
        Args:
            detections: List of Detection objects with classID and mapLocation
        """
        # Separate blocks by color
        friendly_blocks = []
        opponent_blocks = []
        
        robot_x = self._observation[ObsIndex.SELF_POS_X]
        robot_y = self._observation[ObsIndex.SELF_POS_Y]

        def to_scalar(value):
            arr = np.asarray(value)
            if arr.ndim == 0:
                return float(arr)
            if arr.size == 0:
                return np.nan
            return float(arr.reshape(-1)[0])
        
        def clamp(value, min_value, max_value):
            scalar_value = to_scalar(value)
            if np.isnan(scalar_value):
                return scalar_value  # keep NaN as is
            return max(min_value, min(scalar_value, max_value))

        for det in detections:
            # Get map position
            x = clamp(det.mapLocation.x*METERS_TO_INCHES, -72, 72)
            y = clamp(det.mapLocation.y*METERS_TO_INCHES, -72, 72)
            z = clamp(det.mapLocation.z*METERS_TO_INCHES, -72, 72)
            # print(f"[DEBUG] Detection ClassID: {det.classID}, Position: ({x}, {y}, {z})", flush=True)

            if np.isnan(x) or np.isnan(y):
                continue
            
            # Calculate distance from robot for sorting
            dist = np.sqrt((x - robot_x)**2 + (y - robot_y)**2)
            
            # Classify as friendly or opponent based on team
            is_friendly = False
            if self._team == Team.RED and det.classID == self.CLASS_RED_BLOCK:
                is_friendly = True
            elif self._team == Team.BLUE and det.classID == self.CLASS_BLUE_BLOCK:
                is_friendly = True
            
            block_info = (dist, x, y)
            if is_friendly:
                friendly_blocks.append(block_info)
            else:
                opponent_blocks.append(block_info)
        
        # Sort by distance (closest first)
        friendly_blocks.sort(key=lambda b: b[0])
        opponent_blocks.sort(key=lambda b: b[0])
        
        # Update counts
        self._observation[ObsIndex.FRIENDLY_BLOCK_COUNT] = float(len(friendly_blocks))
        self._observation[ObsIndex.OPPONENT_BLOCK_COUNT] = float(len(opponent_blocks))
        
        # Update friendly block positions (up to MAX_TRACKED_BLOCKS)
        for i in range(self.MAX_TRACKED_BLOCKS):
            idx = ObsIndex.FRIENDLY_BLOCKS_START + i * 2
            if i < len(friendly_blocks):
                self._observation[idx] = float(friendly_blocks[i][1])      # x
                self._observation[idx + 1] = float(friendly_blocks[i][2])  # y
            else:
                # Sentinel value for empty slots
                self._observation[idx] = SENTINEL_BLOCK_VALUE
                self._observation[idx + 1] = SENTINEL_BLOCK_VALUE
        
        # Update opponent block positions (up to MAX_TRACKED_BLOCKS)
        for i in range(self.MAX_TRACKED_BLOCKS):
            idx = ObsIndex.OPPONENT_BLOCKS_START + i * 2
            if i < len(opponent_blocks):
                self._observation[idx] = float(opponent_blocks[i][1])      # x
                self._observation[idx + 1] = float(opponent_blocks[i][2])  # y
            else:
                # Sentinel value for empty slots
                self._observation[idx] = SENTINEL_BLOCK_VALUE
                self._observation[idx + 1] = SENTINEL_BLOCK_VALUE
    
    def update_observation(self, index: int, value: float) -> None:
        """Directly update a specific observation index."""
        if 0 <= index < ObsIndex.TOTAL:
            self._observation[index] = value
    
    def get_message_string(self) -> str:
        """Get the latest message vector as a comma-separated string for sending over USB."""
        if self._last_message is None:
            return None
        return ",".join(f"{v:.6f}" for v in self._last_message)


class MainApp:
    def __init__(self):
        # Initialize various components including camera, processing, and rendering
        print("Starting Initialization...", flush=True)
        self.camera = Camera()
        self.camera.start()
        self.processing = Processing(self.camera.depth_scale, self.camera.profile)
        
        self.v5Map = MapPosition()
        self.v5Pos = V5GPS()
        self.v5Web = V5WebData(self.v5Map, self.v5Pos, self.processing)
        self.stats = Statistics(0, 0, 0, 640, 480, 0, False)
        self.rendering = Rendering(self.v5Web)

        # Create the pushback handler for VEXAIRL model management
        self.pushback_handler = PushbackHandler(None, self.v5Web.setCameraOffset, self.v5Web.setGpsOffset, self.v5Pos)

        self.v5 = V5SerialComms(handler=self.pushback_handler)

        self.pushback_handler.set_write_func(self.v5.write)

        time.sleep(1)
        print("Initialized", flush=True)

    def get_v5Pos(self):
        # Return V5Position object if GPS is connected but default values if not connected
        if self.v5Pos is None:
            return Position(0, 0, 0, 0, 0, 0, 0, 0)
        return self.v5Pos.getPosition()

    def set_v5(self, aiRecord):
        # Set detection data to the Brain if it is connected but does not set any data if None
        if self.v5 is not None:
            self.v5.setDetectionData(aiRecord)

    def run(self):
        # Start main loop: capture frames, process, detect objects, compute detections, render and display
        print("Starting V5 communications...", flush=True)
        self.v5.start()
        print("Starting V5 position tracking...", flush=True)
        self.v5Pos.start()
        print("Starting web server...", flush=True)
        self.v5Web.start()
        run_time = time.time()

        # For testing, initialize model directly
        # self.pushback_handler.handle("INIT", "shared_policy,red,15,15,15,65,24,270,-6.5,-3.75,14.25,90,-10,-6.5,1.5,10,270")

        print("\nStarting Loop", flush=True)
        last_message_time = time.time()
        try:
            while True:
                start_time = time.time()  # start time of the loop
                frames = self.camera.get_frames()
                depth_image, color_image, depth_map = self.processing.process_frames(frames)
                if color_image is None:
                    print("Skipping frame - no valid camera data")
                    continue
                invoke_time = time.time()
                output, detections = self.processing.detect_objects(color_image)
                invoke_time = time.time() - invoke_time
                aiRecord = self.processing.compute_detections(self, detections, depth_image)
                
                # Update observation with detected block positions
                self.pushback_handler.handle_detections(aiRecord.detections)

                # Send MESSAGE periodically (every 100ms)
                now = time.time()
                if now - last_message_time >= 0.1:
                    msg_str = self.pushback_handler.get_message_string()
                    if msg_str is not None:
                        self.v5.write("MESSAGE", msg_str)
                    last_message_time = now

                # # For testing
                # self.pushback_handler.handle("START", "60")
                # print("[DEBUG] Detections processed and observation updated.", flush=True)
                
                self.set_v5(aiRecord)
                self.rendering.set_images(output, depth_map)
                self.rendering.set_detection_data(aiRecord)
                self.rendering.set_stats(self.stats, self.v5Pos, start_time, invoke_time, run_time)
                # self.rendering.display_output(output)
        finally:
            self.camera.stop()


if __name__ == "__main__":
    try:
        print("=== Starting VEXAI Application ===", flush=True)
        app = MainApp()  # Create the main application
        app.run()  # Run the application
    except Exception as e:
        print(f"FATAL ERROR: {e}", flush=True)
        import traceback
        traceback.print_exc()
