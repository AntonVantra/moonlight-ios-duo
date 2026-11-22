/* SPDX-License-Identifier: GPL-3.0-only */
#include "../Limelight/Input/DesktopGeometry.h"

#include <assert.h>
#include <stdio.h>

static void near(double expected, double actual) {
    assert(fabs(expected - actual) < 0.01);
}

int main(void) {
    // Apple's landscape inner and outer display dimensions.
    DesktopRect inner = {0, 0, 890, 626};
    DesktopRect outer = {0, 0, 678, 466};
    DesktopPixels pixels = DesktopAdaptivePixels(inner, 3, 3840);
    assert(pixels.width == 2670 && pixels.height == 1878);
    pixels = DesktopAdaptivePixels(outer, 3, 3840);
    assert(pixels.width == 2034 && pixels.height == 1398);
    pixels = DesktopAdaptivePixels((DesktopRect){0, 0, 626, 890}, 3, 3840);
    assert(pixels.width == 1878 && pixels.height == 2670);
    pixels = DesktopAdaptivePixels(inner, 3, 2560);
    assert(pixels.width < 2670 && pixels.width * pixels.height <= 2560 * 1440);
    assert(pixels.width % 2 == 0 && pixels.height % 2 == 0);
    near(2670.0 / 1878, pixels.width / (double)pixels.height);
    assert(DesktopAdaptivePixels((DesktopRect){0}, 3, 3840).width == 0);
    assert(DesktopAdaptivePixels(inner, NAN, 3840).width == 0);
    assert(DesktopAdaptivePixels((DesktopRect){0, 0, 400, 1}, 3, 3840).width == 0);

    DesktopRect fitted = DesktopVideoRect(inner, 16.0 / 9, false);
    near(890, fitted.width);
    near(62.6875, fitted.y);
    DesktopPoint center = DesktopMapPoint(fitted, 445, 313);
    near(0.5, center.x);
    near(0.5, center.y);
    near(0, DesktopMapPoint(fitted, -1, 0).x);
    near(1, DesktopMapPoint(fitted, 1000, 800).y);

    DesktopRect filled = DesktopVideoRect(inner, 16.0 / 9, true);
    near(626, filled.height);
    assert(filled.x < 0);
    near(0.5, DesktopMapPoint(filled, 445, 313).x);
    assert(DesktopMapPoint(filled, 0, 313).x > 0);
    near(0.25, DesktopMapPoint((DesktopRect){20, 100, 400, 300}, 120, 250).x);
    near(0.5, DesktopMapPoint((DesktopRect){20, 100, 400, 300}, 120, 250).y);

    DesktopPanes panes = DesktopLaptopPanes(inner, (DesktopRect){0, 305, 890, 16}, true);
    near(305, panes.video.height);
    near(321, panes.trackpad.y);
    near(626, panes.trackpad.y + panes.trackpad.height);
    panes = DesktopLaptopPanes(inner, (DesktopRect){430, 0, 30, 626}, true);
    assert(panes.video.height > 300 && panes.trackpad.height > 250);
    panes = DesktopLaptopPanes((DesktopRect){0, 0, 800, 220}, (DesktopRect){0}, true);
    near(220, panes.video.height);
    assert(panes.trackpad.height == 0);
    panes = DesktopLaptopPanes(outer, (DesktopRect){0, 200, 678, 12}, false);
    near(466, panes.video.height);
    assert(panes.trackpad.height == 0);

    puts("Desktop geometry checks passed.");
    return 0;
}
