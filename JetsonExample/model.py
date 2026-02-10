import numpy as np
import sys
from PIL import ImageDraw
from data_processing import PreprocessYOLO, ALL_CATEGORIES, CATEGORY_NUM
from model_backend import CUDABackend, CoralBackend, USE_CUDA, USE_CORAL


# Set print options for NumPy, allowing the full array to be printed
np.set_printoptions(threshold=sys.maxsize)

class Model:

    # Confidence threshold for filtering detections
    OBJ_THRESHOLD = 0.25
    # NMS IoU threshold for suppressing overlapping boxes
    NMS_THRESHOLD = 0.5

    def __init__(self):
        if USE_CUDA:
            self.backend = CUDABackend()
            print("Using CUDA for model inferencing")
        elif USE_CORAL:
            self.backend = CoralBackend()
            print("Using Coral Edge TPU for model inferencing")
        else:
            print("No backend found! Make sure you have CUDA or Coral installed based on your device")

    @staticmethod
    def _nms_boxes(boxes, confidences, nms_threshold):
        """Apply Non-Maximum Suppression on boxes in [x, y, w, h] format.

        Returns indices of boxes to keep.
        """
        x = boxes[:, 0]
        y = boxes[:, 1]
        w = boxes[:, 2]
        h = boxes[:, 3]

        areas = w * h
        ordered = confidences.argsort()[::-1]

        keep = []
        while ordered.size > 0:
            i = ordered[0]
            keep.append(i)
            xx1 = np.maximum(x[i], x[ordered[1:]])
            yy1 = np.maximum(y[i], y[ordered[1:]])
            xx2 = np.minimum(x[i] + w[i], x[ordered[1:]] + w[ordered[1:]])
            yy2 = np.minimum(y[i] + h[i], y[ordered[1:]] + h[ordered[1:]])

            inter_w = np.maximum(0.0, xx2 - xx1 + 1)
            inter_h = np.maximum(0.0, yy2 - yy1 + 1)
            intersection = inter_w * inter_h
            union = areas[i] + areas[ordered[1:]] - intersection

            iou = intersection / union
            indexes = np.where(iou <= nms_threshold)[0]
            ordered = ordered[indexes + 1]

        return np.array(keep)

    @staticmethod
    def _postprocess_yolov26(raw_output, shape_orig_WH, input_resolution_HW,
                             obj_threshold, nms_threshold):
        """Convert YOLOv26 output [1, 300, 6] into the same (boxes, classes, scores)
        format that the old YOLOv3 PostprocessYOLO produced.

        YOLOv26 raw_output layout per detection: [x1, y1, x2, y2, confidence, class_id]
        Coordinates are in input-resolution pixel space (e.g. 320x320).

        Returns
        -------
        boxes : ndarray (N, 4)  [x, y, w, h] in original image pixels (top-left origin)
        classes : ndarray (N,)  integer class IDs
        scores : ndarray (N,)   confidence values
        All three are None when no detections survive filtering.
        """
        detections = raw_output.reshape(-1, 6)  # (300, 6)

        confs = detections[:, 4]
        mask = confs >= obj_threshold
        detections = detections[mask]

        if detections.shape[0] == 0:
            return None, None, None

        # Filter out detections with invalid class IDs (must be 0..CATEGORY_NUM-1)
        class_ids = detections[:, 5].astype(int)
        valid_class_mask = (class_ids >= 0) & (class_ids < CATEGORY_NUM)
        detections = detections[valid_class_mask]

        if detections.shape[0] == 0:
            return None, None, None

        # Extract fields
        x1 = detections[:, 0]
        y1 = detections[:, 1]
        x2 = detections[:, 2]
        y2 = detections[:, 3]
        scores = detections[:, 4]
        classes = detections[:, 5].astype(int)

        # Convert from xyxy to xywh (top-left, width, height)
        w = x2 - x1
        h = y2 - y1
        boxes = np.stack([x1, y1, w, h], axis=-1)

        # Scale from input resolution to original image size
        inp_h, inp_w = input_resolution_HW
        orig_w, orig_h = shape_orig_WH
        scale_x = orig_w / inp_w
        scale_y = orig_h / inp_h
        boxes[:, 0] *= scale_x
        boxes[:, 2] *= scale_x
        boxes[:, 1] *= scale_y
        boxes[:, 3] *= scale_y

        # Per-class NMS (same logic the old pipeline used)
        nms_boxes, nms_classes, nms_scores = [], [], []
        for cls in set(classes):
            idxs = np.where(classes == cls)[0]
            cls_boxes = boxes[idxs]
            cls_scores = scores[idxs]
            keep = Model._nms_boxes(cls_boxes, cls_scores, nms_threshold)
            nms_boxes.append(cls_boxes[keep])
            nms_classes.append(classes[idxs][keep])
            nms_scores.append(cls_scores[keep])

        if not nms_boxes:
            return None, None, None

        boxes = np.concatenate(nms_boxes)
        classes = np.concatenate(nms_classes)
        scores = np.concatenate(nms_scores)

        return boxes, classes, scores

    def inference(self, inputImage):
        # Perform inference on the given image and return the bounding boxes, scores, and classes of detected objects.

        # Define input resolution and create preprocessor
        input_resolution_HW = (640, 640)
        preprocessor = PreprocessYOLO(input_resolution_HW)

        # Process the image and get original shape
        image_raw, image = preprocessor.process(inputImage, self.backend.dtype)
        shape_orig_WH = image_raw.size

        # Run model inference (YOLOv26 output shape: [1, 300, 6])
        outputs = self.backend.inference(image)

        # YOLOv26 produces a single output tensor [1, 300, 6]
        # Each detection: [x1, y1, x2, y2, confidence, class_id]
        raw_output = outputs[0] if isinstance(outputs, (list, tuple)) else outputs

        boxes, classes, scores = Model._postprocess_yolov26(
            raw_output, shape_orig_WH, input_resolution_HW,
            self.OBJ_THRESHOLD, self.NMS_THRESHOLD,
        )

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
