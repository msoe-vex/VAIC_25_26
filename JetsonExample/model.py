import numpy as np
import sys
from PIL import ImageDraw
from data_processing import PreprocessYOLO, PostprocessYOLO, ALL_CATEGORIES
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
        input_resolution_yolov3_HW = (320, 320)
        preprocessor = PreprocessYOLO(input_resolution_yolov3_HW)

        # Process the image and get original shape
        image_raw, image = preprocessor.process(inputImage, self.backend.dtype)
        shape_orig_WH = image_raw.size

        # Define output shapes for post-processing
        output_shapes = [(1, 10, 10, 21), (1, 20, 20, 21)]

        # Set the input and perform inference
        outputs = self.backend.inference(image)

        # Sort tensors from smallest to largest
        outputs = sorted(outputs, key=lambda o: o.size)

        # Reshape the outputs for post-processing
        outputs = [output.reshape(shape) for output, shape in zip(outputs, output_shapes)]

        # Define arguments for post-processing
        postprocessor_args = {
            "yolo_masks": [(3, 4, 5), (0, 1, 2)],
            "yolo_anchors": [
            (10, 14),
            (23, 27),
            (37, 58),
            (81, 82),
            (135, 169),
            (344, 319),
            ],
            "obj_threshold": [0.5, 0.5],  # Different thresholds for each class label (Green, Red, Blue)
            "nms_threshold": 0.5,
            "yolo_input_resolution": input_resolution_yolov3_HW,
        }

        # Perform post-processing
        postprocessor = PostprocessYOLO(**postprocessor_args)
        boxes, classes, scores = postprocessor.process(outputs, (shape_orig_WH))

        Detections = []

        # Handle case with no detections
        if boxes is None or classes is None or scores is None:
            #print("No objects were detected.")
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
            x_coord, y_coord, width, height = box
            left = max(0, np.floor(x_coord + 0.5).astype(int))
            top = max(0, np.floor(y_coord + 0.5).astype(int))
            right = min(image_raw.width, np.floor(x_coord + width + 0.5).astype(int))
            bottom = min(image_raw.height, np.floor(y_coord + height + 0.5).astype(int))

            # Draw the rectangle and text
            # draw.rectangle(((left, top), (right, bottom)), outline=bbox_color)
            # draw.text((left, top - 12), "{0} {1:.2f}".format(all_categories[category], score), fill=bbox_color)

            # Create and store the raw detection object
            raw_detection = rawDetection(int(left), int(top), [x_coord, y_coord], int(width), int(height), score,
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
