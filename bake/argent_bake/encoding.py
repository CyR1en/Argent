"""Log encoding shared with LUT3D.swift. Keep the two in step.

The Negative LUT's input is scene-linear Rec. 2020 RGB log-encoded per channel. Defaults
cover eight stops below mid-gray (0.18) and five above. Film bakes declare a wider domain
in the manifest, which the Swift loader reads.
"""

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class LogEncoding:
    stops_below_mid_gray: float = 8.0
    stops_above_mid_gray: float = 5.0
    mid_gray: float = 0.18

    @property
    def range(self) -> float:
        return self.stops_below_mid_gray + self.stops_above_mid_gray

    def encode(self, linear: float) -> float:
        stops = math.log2(max(linear, 1e-6) / self.mid_gray)
        return min(max((stops + self.stops_below_mid_gray) / self.range, 0.0), 1.0)

    def decode(self, encoded: float) -> float:
        return self.mid_gray * 2.0 ** (encoded * self.range - self.stops_below_mid_gray)
