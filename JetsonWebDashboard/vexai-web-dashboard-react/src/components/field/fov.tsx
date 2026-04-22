import React from "react";
import { Arc } from "react-konva";
import { useAppSelector } from "../../state/hooks";
import { config } from "../../util/config";

interface FovProps {
  fieldHeight: number;
}

/**
 * Applies a light, transparent mask to the field for showing the robot's field of view
 *
 * @param param0 Fov properties
 * @returns JSX.Element
 */
const Fov = ({ fieldHeight }: FovProps) => {
  const position = useAppSelector((state) => state.data.response.position);
  const scale = useAppSelector((state) => state.app.scale);
  const cameraHeadingOffset =
    useAppSelector((state) => state.settings.cameraOffset.headingOffset) ?? 0;

  const robotHeading = position ? (position.rotation ?? position.azimuth ?? 0) : 0;
  const cameraHeading = robotHeading - cameraHeadingOffset;

  return (
    position ? (
      <Arc
        x={position.x * scale}
        y={position.y * scale * -1}
        rotation={cameraHeading - 90 - config.field.robot.fov / 2}
        innerRadius={0}
        outerRadius={fieldHeight * 2}
        fill="white"
        angle={config.field.robot.fov}
        opacity={1}
        globalCompositeOperation="destination-out"
      />
    ) : null
  );
};

export default Fov;
