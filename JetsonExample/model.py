import numpy as np
import sys
from PIL import ImageDraw
from data_processing import PreprocessYOLO, ALL_CATEGORIES
from model_backend import CUDABackend, CoralBackend, USE_CUDA, USE_CORAL


# Set print options for NumPy, allowing the full array to be printed
np.set_printoptions(threshold=sys.maxsize)

class Model:

    def __init__(self):
        if USE_CUDA:
            self.backend = CUDABackend()
            print("Using CUDA for model inferencing")
        elif USE_CORAL:
            self.backend = CoralBackend()
            print("Using Coral Edge TPU for model inferencing")
        else:
            print("No backend found! Make sure you have CUDA or Coral installed based on your device")

    def inference(self, inputImage):
        # Perform inference on the given image and return the bounding boxes, scores, and classes of detected objects.

        # Define input resolution and create preprocessor
        input_resolution_yolov3_HW = (640, 640)
        preprocessor = PreprocessYOLO(input_resolution_yolov3_HW)

        # Process the image and get original shape
        image_raw, image = preprocessor.process(inputImage, self.backend.dtype)
        # Set the input and perform inference
        outputs = self.backend.inference(image)

        # Expected single output: (1, 300, 6) => [x1, y1, x2, y2, conf, class]
        output = outputs[0].reshape((1, 300, 6))[0]

        boxes = output[:, 0:4]
        scores = output[:, 4]
        classes = output[:, 5].astype(int)

        Detections = []

        # Handle case with no detections
        if boxes is None or classes is None or scores is None:
            #print("No objects were detected.")
            return inputImage, Detections

        # Filter invalid and low-confidence boxes before drawing
        valid = scores > 0.0
        if np.any(valid):
            boxes = boxes[valid]
            scores = scores[valid]
            classes = classes[valid]
        else:
            return inputImage, Detections

        # Draw bounding boxes and return detected objects
        obj_detected_img = Model.draw_bboxes(image_raw, boxes, scores, classes, ALL_CATEGORIES, Detections)
        return np.array(obj_detected_img), Detections

    @staticmethod
    def draw_bboxes(image_raw, bboxes, confidences, categories, all_categories, Detections, bbox_color="white"):
        # Draw bounding boxes on the original image and return it.

        # Create drawing context
        draw = ImageDraw.Draw(image_raw)

        # Draw each bounding box
        for box, score, category in zip(bboxes, confidences, categories):
            x1, y1, x2, y2 = box
            left = max(0, np.floor(x1 + 0.5).astype(int))
            top = max(0, np.floor(y1 + 0.5).astype(int))
            right = min(image_raw.width, np.floor(x2 + 0.5).astype(int))
            bottom = min(image_raw.height, np.floor(y2 + 0.5).astype(int))

            width = max(0, right - left)
            height = max(0, bottom - top)

            # Draw the rectangle and text
            # draw.rectangle(((left, top), (right, bottom)), outline=bbox_color)
            # draw.text((left, top - 12), "{0} {1:.2f}".format(all_categories[category], score), fill=bbox_color)

            # Create and store the raw detection object
            raw_detection = rawDetection(int(left), int(top), [x1, y1], int(width), int(height), score,
                                         category)
            Detections.append(raw_detection)

        return image_raw


class rawDetection:
    def __init__(self, x: int, y: int, center: [], width: int, height: int, prob: float, classID: int):
        # Class to store information about a detected object.

        self.x = x
        self.y = y
        self.Center = center
        self.Width = width
        self.Height = height
        self.Prob = prob
        self.ClassID = classID
