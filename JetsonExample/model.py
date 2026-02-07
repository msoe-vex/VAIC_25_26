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
            self.backend = None

        self._num_classes = len(ALL_CATEGORIES)
        self._input_resolution = self._resolve_input_resolution()

    def _resolve_input_resolution(self):
        if self.backend is not None and hasattr(self.backend, "input_resolution"):
            return self.backend.input_resolution
        return (320, 320)

    def _resolve_input_layout(self):
        if self.backend is not None and hasattr(self.backend, "input_layout"):
            return self.backend.input_layout
        return "NHWC"

    def _infer_output_shapes(self, outputs):
        channel_size = 3 * (5 + self._num_classes)
        output_shapes = []
        for output in outputs:
            size = output.size
            if size % channel_size != 0:
                continue
            grid = int(round(np.sqrt(size / channel_size)))
            if grid * grid * channel_size != size:
                continue
            output_shapes.append((1, grid, grid, channel_size))
        return output_shapes

    def _backend_output_shapes(self):
        if self.backend is not None and hasattr(self.backend, "output_shapes"):
            shapes = [tuple(s) for s in self.backend.output_shapes]
            shapes = [s for s in shapes if len(s) == 4]
            if shapes:
                shapes.sort(key=lambda s: np.prod(s))
                return shapes
        return []

    def _resolve_shape(self, output, shape):
        if output.ndim == 4:
            return output.shape
        shape = list(shape)
        if -1 in shape:
            known = 1
            unknown_count = 0
            for dim in shape:
                if dim == -1:
                    unknown_count += 1
                else:
                    known *= dim
            if unknown_count == 1 and known > 0:
                shape[shape.index(-1)] = int(output.size // known)
        return tuple(shape)

    def _to_nhwc(self, output):
        channel_size = 3 * (5 + self._num_classes)
        if output.ndim == 4 and output.shape[1] == channel_size and output.shape[-1] != channel_size:
            return np.transpose(output, [0, 2, 3, 1])
        return output

    def _scaled_anchors(self, input_resolution):
        base_anchors = [
            (10, 14),
            (23, 27),
            (37, 58),
            (81, 82),
            (135, 169),
            (344, 319),
        ]
        scale = input_resolution[0] / 416.0
        return [(a[0] * scale, a[1] * scale) for a in base_anchors]

    def inference(self, inputImage):
        # Perform inference on the given image and return the bounding boxes, scores, and classes of detected objects.
        if self.backend is None:
            print("No backend available for inference.")
            return inputImage, []

        # Define input resolution and create preprocessor
        input_resolution_yolov3_HW = self._input_resolution
        preprocessor = PreprocessYOLO(input_resolution_yolov3_HW)

        # Process the image and get original shape
        image_raw, image = preprocessor.process(inputImage, self.backend.dtype)
        if self._resolve_input_layout() == "NCHW":
            image = np.transpose(image, [0, 3, 1, 2])

        image = np.ascontiguousarray(image)
        shape_orig_WH = image_raw.size

        # Set the input and perform inference
        outputs = self.backend.inference(image)

        # Sort tensors from smallest to largest
        outputs = sorted(outputs, key=lambda o: o.size)

        # Fallback: handle single-output models that already include NMS
        if len(outputs) == 1 and outputs[0].size % 6 == 0:
            detections = self._postprocess_nms_output(outputs[0], shape_orig_WH)
            return np.array(image_raw), detections

        # Reshape the outputs for post-processing
        output_shapes = self._infer_output_shapes(outputs)
        if len(output_shapes) != len(outputs):
            output_shapes = self._backend_output_shapes()
        if len(output_shapes) != len(outputs):
            output_sizes = [int(o.size) for o in outputs]
            backend_shapes = self._backend_output_shapes()
            print(f"[WARN] Unexpected output sizes; skipping detections. sizes={output_sizes}, backend_shapes={backend_shapes}")
            return inputImage, []
        resolved_shapes = [self._resolve_shape(output, shape) for output, shape in zip(outputs, output_shapes)]
        outputs = [output.reshape(shape) for output, shape in zip(outputs, resolved_shapes)]
        outputs = [self._to_nhwc(output) for output in outputs]

        # Define arguments for post-processing
        postprocessor_args = {
            "yolo_masks": [(3, 4, 5), (0, 1, 2)],
            "yolo_anchors": self._scaled_anchors(input_resolution_yolov3_HW),
            "obj_threshold": [0.25, 0.25],  # Very low threshold for debugging
            "nms_threshold": 0.5,
            "yolo_input_resolution": input_resolution_yolov3_HW,
        }

        # Perform post-processing
        postprocessor = PostprocessYOLO(**postprocessor_args)
        
        # Debug: Check raw model output values BEFORE postprocessing
        for i, out in enumerate(outputs):
            obj_channel = out[..., 4]  # Objectness scores are at index 4
            # Apply sigmoid to get actual confidence
            obj_sigmoid = 1.0 / (1.0 + np.exp(-obj_channel))
        
        boxes, classes, scores = postprocessor.process(outputs, (shape_orig_WH))

        Detections = []

        # Handle case with no detections
        if boxes is None or classes is None or scores is None:
            #print("No objects were detected.")
            return inputImage, Detections

        # Draw bounding boxes and return detected objects
        obj_detected_img = Model.draw_bboxes(image_raw, boxes, scores, classes, ALL_CATEGORIES, Detections)
        return np.array(obj_detected_img), Detections

    def _postprocess_nms_output(self, output, shape_orig_WH, conf_threshold=0.25):
        width, height = shape_orig_WH
        if output.ndim == 1:
            dets = output.reshape(-1, 6)
        elif output.ndim == 2 and output.shape[1] == 6:
            dets = output
        elif output.ndim == 3 and output.shape[-1] == 6:
            dets = output.reshape(-1, 6)
        else:
            return []

        Detections = []

        max_val = np.max(dets[:, :4]) if dets.size else 0
        normalized = max_val <= 1.5

        for row in dets:
            x1, y1, x2, y2, conf, cls = row
            if conf < conf_threshold:
                continue

            # If coordinates look like xywh (center format), convert to xyxy
            if x2 < x1 or y2 < y1:
                x, y, w, h = x1, y1, x2, y2
                x1 = x - w / 2
                y1 = y - h / 2
                x2 = x + w / 2
                y2 = y + h / 2

            if normalized:
                x1 *= width
                x2 *= width
                y1 *= height
                y2 *= height

            x1 = max(0, min(width, x1))
            x2 = max(0, min(width, x2))
            y1 = max(0, min(height, y1))
            y2 = max(0, min(height, y2))

            w = max(0, x2 - x1)
            h = max(0, y2 - y1)
            if w == 0 or h == 0:
                continue

            raw_detection = rawDetection(
                int(x1),
                int(y1),
                [float((x1 + x2) / 2), float((y1 + y2) / 2)],
                int(w),
                int(h),
                float(conf),
                int(cls),
            )
            Detections.append(raw_detection)

        return Detections

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
    def __init__(self, x: int, y: int, center: list, width: int, height: int, prob: float, classID: int):
        # Class to store information about a detected object.

        self.x = x
        self.y = y
        self.Center = center
        self.Width = width
        self.Height = height
        self.Prob = prob
        self.ClassID = classID
