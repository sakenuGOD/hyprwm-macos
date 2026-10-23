#pragma once

// Visible menus/panels must survive the snapshot even when small or above layer zero.
static int snapshot_include(int layer, int on, double width, double height) {
    return width > 0 && height > 0 && (layer == 0 || on);
}
