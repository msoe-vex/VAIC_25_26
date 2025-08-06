import React from "react";
import { Layer, Image } from "react-konva";
import { config } from "../../util/config";
import { useAppSelector } from "../../state/hooks";
import { Element } from "../../lib/types";
import { v4 as uuidv4 } from "uuid";
import useImage from "use-image";

interface DetectionLayerProps {
  fieldWidth: number;
  fieldHeight: number;
}

/**
 * Displays elements on the field detected by the robot
 *
 * @param param0 Detection layer properties
 * @returns JSX.Element
 */
const DetectionLayer = ({ fieldWidth, fieldHeight }: DetectionLayerProps) => {
  const detections = useAppSelector((state) => state.data.response.detections);
  const scale = useAppSelector((state) => state.app.scale);
  const [redPickup] = useImage(config.elements.textures[Element.BallRed]);
  const [bluePickup] = useImage(config.elements.textures[Element.BallBlue]);

  const getImage = (detectionClass: number) => {
    switch (detectionClass) {
      case Element.BallRed:
        return redPickup;
      case Element.BallBlue:
        return bluePickup;
      default:
        break;
    }
  };

  return (
    <Layer>
      {detections ? (
        <>
          {detections.map((detection) => {
            const widthScale = scale * config.elements.size[detection.class].width * config.elements.size[detection.class].scale;
            const heightScale = scale * config.elements.size[detection.class].height * config.elements.size[detection.class].scale;
            return (
              <>
                {detection.depth !== -1 ? (
                  <Image
                    key={`${
                      config.elements.label.text[detection.class]
                    }-${uuidv4()}`}
                    alt=""
                    image={getImage(detection.class)}
                    x={detection.mapLocation.x[0] * scale * config.elements.size[detection.class].scale}
                    y={detection.mapLocation.y[0] * scale * -1 * config.elements.size[detection.class].scale}
                    z={detection.depth}
                    width={widthScale}
                    height={heightScale}
                    offsetX={widthScale / 2}
                    offsetY={widthScale / 2}
                  />
                ) : null}
              </>
            );
          })}
        </>
      ) : null}
    </Layer>
  );
};

export default DetectionLayer;
