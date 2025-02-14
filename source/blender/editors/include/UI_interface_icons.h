/*
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 *
 * The Original Code is Copyright (C) 2001-2002 by NaN Holding BV.
 * All rights reserved.
 */

/** \file
 * \ingroup editorui
 */

#pragma once

/* Required for #eIconSizes which can't be forward declared if this file is included in C++. */
#include "DNA_ID_enums.h"

#ifdef __cplusplus
extern "C" {
#endif

struct Collection;
struct ID;
struct PointerRNA;
struct PreviewImage;
struct Scene;
struct bContext;

typedef struct IconFile {
  struct IconFile *next, *prev;
  char filename[256]; /* FILE_MAXFILE size */
  int index;
} IconFile;

#define ICON_DEFAULT_HEIGHT 16
#define ICON_DEFAULT_WIDTH 16

#define ICON_DEFAULT_HEIGHT_TOOLBAR 32

#define ICON_DEFAULT_HEIGHT_SCALE ((int)(UI_UNIT_Y * 0.8f))
#define ICON_DEFAULT_WIDTH_SCALE ((int)(UI_UNIT_X * 0.8f))

#define PREVIEW_DEFAULT_HEIGHT 128

typedef enum eAlertIcon {
  ALERT_ICON_WARNING = 0,
  ALERT_ICON_QUESTION = 1,
  ALERT_ICON_ERROR = 2,
  ALERT_ICON_INFO = 3,
  ALERT_ICON_BLENDER = 4,
  ALERT_ICON_MAX,
} eAlertIcon;

struct ImBuf *UI_icon_alert_imbuf_get(eAlertIcon icon);

/**
 * Resizable Icons for Blender
 */
void UI_icons_init(void);
/**
 * Reload the textures for internal icons.
 * This function will release the previous textures.
 */
void UI_icons_reload_internal_textures(void);

/**
 * NOTE: returns unscaled by DPI.
 */
int UI_icon_get_width(int icon_id);
int UI_icon_get_height(int icon_id);
bool UI_icon_get_theme_color(int icon_id, unsigned char color[4]);

/**
 * Note that if an ID doesn't support jobs for preview creation, \a use_job will be ignored.
 */
void UI_icon_render_id(const struct bContext *C,
                       struct Scene *scene,
                       struct ID *id,
                       enum eIconSizes size,
                       bool use_job);
/**
 * Render size for preview images and icons
 */
int UI_icon_preview_to_render_size(enum eIconSizes size);

/**
 * Draws icon with dpi scale factor.
 */
void UI_icon_draw(float x, float y, int icon_id);
void UI_icon_draw_alpha(float x, float y, int icon_id, float alpha);
void UI_icon_draw_preview(float x, float y, int icon_id, float aspect, float alpha, int size);

void UI_icon_draw_ex(float x,
                     float y,
                     int icon_id,
                     float aspect,
                     float alpha,
                     float desaturate,
                     const uchar mono_color[4],
                     bool mono_border);

void UI_icons_free(void);
void UI_icons_free_drawinfo(void *drawinfo);

void UI_icon_draw_cache_begin(void);
void UI_icon_draw_cache_end(void);

struct ListBase *UI_iconfile_list(void);
int UI_iconfile_get_index(const char *filename);

struct PreviewImage *UI_icon_to_preview(int icon_id);

int UI_icon_from_rnaptr(const struct bContext *C, struct PointerRNA *ptr, int rnaicon, bool big);
int UI_icon_from_idcode(int idcode);
int UI_icon_from_library(const struct ID *id);
int UI_icon_from_object_mode(int mode);
int UI_icon_color_from_collection(const struct Collection *collection);

#ifdef __cplusplus
}
#endif
