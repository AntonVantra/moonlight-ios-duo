/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef DESKTOP_GEOMETRY_H
#define DESKTOP_GEOMETRY_H

#include <math.h>
#include <stdbool.h>

typedef struct { double x, y, width, height; } DesktopRect;
typedef struct { int width, height; } DesktopPixels;
typedef struct { double x, y; } DesktopPoint;
typedef struct { DesktopRect video, trackpad; } DesktopPanes;

static inline bool DesktopRectIsUsable(DesktopRect r) {
    return isfinite(r.x) && isfinite(r.y) && isfinite(r.width) &&
           isfinite(r.height) && r.width > 0 && r.height > 0;
}

static inline DesktopRect DesktopVideoRect(DesktopRect viewport, double aspect, bool fill) {
    if (!DesktopRectIsUsable(viewport) || !isfinite(aspect) || aspect <= 0) {
        return (DesktopRect){0};
    }
    double widthForHeight = viewport.height * aspect;
    double width = fill ? fmax(viewport.width, widthForHeight) : fmin(viewport.width, widthForHeight);
    double height = width / aspect;
    return (DesktopRect){
        viewport.x + (viewport.width - width) / 2,
        viewport.y + (viewport.height - height) / 2,
        width, height
    };
}

// Sunshine centers a differently shaped desktop inside the encoded frame.
static inline DesktopRect DesktopEncodedFrame(DesktopRect viewport, double encodedAspect,
                                              double captureAspect, bool fill) {
    if (captureAspect <= 0 || !isfinite(captureAspect) || encodedAspect <= 0 || !isfinite(encodedAspect)) {
        return DesktopVideoRect(viewport, encodedAspect, fill);
    }
    DesktopRect source = DesktopVideoRect((DesktopRect){0, 0, encodedAspect, 1}, captureAspect, false);
    DesktopRect target = DesktopVideoRect(viewport, captureAspect, fill);
    double scale = target.width / source.width;
    return (DesktopRect){target.x - source.x * scale, target.y - source.y * scale,
                         encodedAspect * scale, scale};
}

static inline DesktopPoint DesktopMapPoint(DesktopRect video, double x, double y) {
    if (!DesktopRectIsUsable(video) || !isfinite(x) || !isfinite(y)) {
        return (DesktopPoint){0};
    }
    return (DesktopPoint){fmin(fmax((x - video.x) / video.width, 0), 1),
                          fmin(fmax((y - video.y) / video.height, 0), 1)};
}

static inline DesktopPixels DesktopAdaptivePixels(DesktopRect viewport, double scale, int maxLongEdge) {
    if (!DesktopRectIsUsable(viewport) || !isfinite(scale) || scale <= 0 || maxLongEdge < 640) {
        return (DesktopPixels){0};
    }
    double width = viewport.width * scale;
    double height = viewport.height * scale;
    double longEdge = fmax(width, height);
    double shortEdge = fmin(width, height);
    if (!isfinite(longEdge) || shortEdge <= 0 || longEdge / shortEdge > 4) {
        return (DesktopPixels){0};
    }
    // Cap decoding cost at 4K and keep even dimensions for 4:2:0 encoders.
    double pixelBudget = (double)maxLongEdge * maxLongEdge * 9 / 16;
    double factor = fmin(1, fmin(maxLongEdge / longEdge, sqrt(pixelBudget / width / height)));
    factor = fmax(factor, 256 / shortEdge);
    if (longEdge * factor > maxLongEdge) {
        return (DesktopPixels){0};
    }
    return (DesktopPixels){(int)floor(width * factor / 2) * 2,
                           (int)floor(height * factor / 2) * 2};
}

static inline bool DesktopResolutionChanged(int oldWidth, int oldHeight, DesktopPixels next) {
    if (oldWidth <= 0 || oldHeight <= 0 || next.width <= 0 || next.height <= 0) {
        return false;
    }
    double widthRatio = (double)next.width / oldWidth;
    double heightRatio = (double)next.height / oldHeight;
    double aspectRatio = widthRatio / heightRatio;
    double areaRatio = widthRatio * heightRatio;
    return fabs(log(aspectRatio)) > log(1.12) || fabs(log(areaRatio)) > log(1.25);
}

static inline DesktopPanes DesktopLaptopPanes(DesktopRect bounds, DesktopRect hinge, bool laptop) {
    DesktopPanes full = {.video = bounds};
    if (!laptop || !DesktopRectIsUsable(bounds) || bounds.width < 320 || bounds.height < 320) {
        return full;
    }

    double topEnd = bounds.y + floor(bounds.height * 0.54);
    double bottomStart = topEnd + 1;
    double boundsEnd = bounds.y + bounds.height;
    // A vertical hinge still works with the manual toggle. Only an actual
    // horizontal division decides the boundary between the upper and lower panes.
    if (DesktopRectIsUsable(hinge) && hinge.width >= bounds.width * 0.75 &&
        hinge.y - bounds.y >= 120 && boundsEnd - hinge.y - hinge.height >= 120) {
        topEnd = hinge.y;
        bottomStart = hinge.y + hinge.height;
    }
    DesktopPanes panes = {
        .video = {bounds.x, bounds.y, bounds.width, topEnd - bounds.y},
        .trackpad = {bounds.x, bottomStart, bounds.width, boundsEnd - bottomStart}
    };
    return panes;
}

#endif
